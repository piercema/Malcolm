#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import json
import logging
import time

from malcolm_utils import AtomicInt, ContextLockedOrderedDict, same_file_or_dir

from watchdog.events import (
    FileSystemEventHandler,
    FileSystemMovedEvent,
    FileModifiedEvent,
    FileCreatedEvent,
    FileClosedEvent,
    FileOpenedEvent,
    FileDeletedEvent,
)

from multiprocessing.pool import ThreadPool
from watchdog.utils import WatchdogShutdown
from watchdog.observers import Observer
from watchdog.observers.polling import PollingObserver
from collections import namedtuple, defaultdict, OrderedDict

ASSUME_CLOSED_SEC_DEFAULT = 10

OperationEvent = namedtuple("OperationEvent", ["timestamp", "operation", "size"], rename=False)


###################################################################################################
class FileOperationEventHandler(FileSystemEventHandler):
    def __init__(
        self,
        logger,
        polling,
        *args,
        **kwargs,
    ):
        super().__init__(*args, **kwargs)
        self.polling = polling
        self.logger = logger if logger else logging
        self.updateTime()
        # self.deck is a dictionary mapping filenames to a list of OperationEvent of length n,
        #   with [0] being the oldest timestamp/operation and [n-1] being the newest
        #   timestamp/operation.
        # In self.deck itself, items at the first (idx=0) of this OrderedDict are the
        #   oldest, items at the last (idx=len-1) are the newest.
        self.deck = ContextLockedOrderedDict()
        # because of the pain in the butt that is the fact that we get the modify events
        #   on attributes-only changes (see below where I set fSize), if events show up
        #   for files and we've ONLY seen open and/or attribute-only modify events (i.e.,
        #   the size doesn't change) then we're just going to hold on to them here in
        #   self.modDeck until we promote them to self.deck for processing.
        #   Once gorakhargosh/watchdog#800 is pulled (resolving gorakhargosh/watchdog#260)
        #   we can get rid of this complication and just ignore attribute-only events.
        self.modDeck = OrderedDict()

    def done(self):
        return True

    def updateTime(self):
        self.nowTime = int(time.time())

    def on_any_event(self, event):
        fName = None
        if not event.is_directory:
            self.updateTime()

            # if this is a move event, we need to track the old and new filenames
            if isinstance(event, FileSystemMovedEvent):
                fName = event.dest_path
                fNameOld = event.src_path
                self.logger.debug(f"↦\t{event.event_type: >10}\t{event.src_path} {event.dest_path}")
            else:
                fName = event.src_path
                fNameOld = None
                self.logger.debug(f"🗲\t{event.event_type: <10}\t{event.src_path}")

            # This is a pain, but due to this watchdog issue (see
            # https://github.com/gorakhargosh/watchdog/issues/260 and
            # https://github.com/gorakhargosh/watchdog/pull/800)
            # we get FileModifiedEvent triggered for metadata-only changes
            # even if content has not changed (e.g., file access time).
            # So for now, if we detect a file has been modified but the size
            # hasn't changed, we will ignore that event.
            try:
                fSize = os.path.getsize(fName)
            except Exception:
                fSize = 0

            # FileClosedEvent is only going to come from inotify events, not polling
            # so we know we're good to go (a FileClosedEvent signals we can process the
            # file immediately). We can signal this by setting the timestamp to 0.
            newOpLog = OperationEvent(
                self.nowTime if (not isinstance(event, FileClosedEvent)) else 0,
                event.event_type,
                fSize,
            )
            noop = False

            with self.deck as d:
                try:
                    deckInserted = d

                    if fNameOld and same_file_or_dir(os.path.dirname(fNameOld), os.path.dirname(fName)):
                        # a file was simply renamed in the watched directory (not moved
                        # from some other directory) so remove the old filename from our list
                        # and a new one will get added
                        if fNameOld in d:
                            d.pop(fNameOld, None)
                        if fNameOld in self.modDeck:
                            self.modDeck(d.pop(fNameOld, None))

                    # insert or update file event(s)

                    if fName in d:
                        # this is a file we're already currently tracking in main deck

                        # see comment about fSize above (FileModifiedEvent only counts if the file size is changed)
                        if (
                            isinstance(event, FileModifiedEvent)
                            and (newOpLog.size > 0)
                            and (len(d[fName]) > 0)
                            and (newOpLog.size == d[fName][-1].size)
                        ):
                            # don't do *anything*, leave the entry untouched in the list
                            noop = True

                        elif (len(d[fName]) > 0) and (d[fName][-1].operation == event.event_type):
                            # if the previous operation (the last one in the history) was the same as this one,
                            # replace the operation rather than appending a new one (effectively just updating the timestamp)
                            if (newOpLog.timestamp > d[fName][-1].timestamp) or (newOpLog.size != d[fName][-1].size):
                                d[fName][-1] = newOpLog

                        else:
                            # otherwise append a new history item
                            d[fName].append(newOpLog)

                    elif fName in self.modDeck:
                        # we've seen this entry before, but it's in the staging modDeck

                        modifyOpSizes = [
                            optLog.size for optLog in self.modDeck[fName] if optLog.operation == "modified"
                        ]
                        # promote to main deck if either:
                        # - this is something more than just an open/modify attribute event OR
                        # - this is a modified event, but the size is different now so it is an actual modification
                        if (not isinstance(event, FileOpenedEvent) and not isinstance(event, FileModifiedEvent)) or (
                            isinstance(event, FileModifiedEvent)
                            and (len(modifyOpSizes) > 0)
                            and (newOpLog.size > 0)
                            and (newOpLog.size != modifyOpSizes[-1])
                        ):
                            # promote what's already in modDec to the real deck, then append this new history item
                            self.logger.debug(f"𝦸\t{event.event_type: <10}\t{fName}")
                            d[fName] = self.modDeck.pop(fName)
                            d[fName].append(newOpLog)

                    else:
                        # this is a file we were not previously tracking at all, in either deck

                        if isinstance(event, FileOpenedEvent) or isinstance(event, FileModifiedEvent):
                            # this is the very first time we've seen this file, if this
                            # is "open" or "modified" with no other context yet then
                            # put it in modDec until it shows up like a real modification
                            deckInserted = self.modDeck

                        deckInserted[fName] = [newOpLog]

                    # move the file to the appropriate end of its deck, if needed
                    if not noop:
                        if (
                            isinstance(event, FileModifiedEvent)
                            or isinstance(event, FileClosedEvent)
                            or isinstance(event, FileCreatedEvent)
                            or isinstance(event, FileSystemMovedEvent)
                        ):
                            # put FileClosedEvent events (which now have a timestamp of 0) at the front of
                            # the deck (to be processed first), and others to the back
                            deckInserted.move_to_end(fName, last=deckInserted[fName][-1].timestamp > 0)

                        elif isinstance(event, FileDeletedEvent):
                            # if a file is deleted I guess we don't need to track it any more
                            deckInserted.pop(fName, None)
                            fName = None

                        else:
                            noop = True

                    if noop:
                        self.logger.debug(f"🗑\t{event.event_type: <10}\t{fName}")

                    elif fName:
                        if fName in d:
                            self.logger.debug(f"➊\t{fName}\t{json.dumps(d[fName])}")
                        if fName in self.modDeck:
                            self.logger.debug(f"➋\t{fName}\t{json.dumps(self.modDeck[fName])}")

                except Exception as e:
                    self.logger.error(f"⨳\t{fName}\t{e}")


###################################################################################################
def ProcessFileEventWorker(workerArgs):
    handler, observer, fileProcessor, fileProcessorKwargs, assumeClosedSec, workerThreadCount, shutDown, logger = (
        workerArgs[0],
        workerArgs[1],
        workerArgs[2],
        workerArgs[3],
        workerArgs[4],
        workerArgs[5],
        workerArgs[6],
        workerArgs[7],
    )
    if not logger:
        logger = logging

    with workerThreadCount as workerId:
        logger.info(f"۞\tstarted\t[{workerId}]")

        while (not shutDown[0]) and observer.is_alive():
            time.sleep(0.5)
            nowTime = int(time.time())

            with handler.deck as d:
                for fileName, fileHistory in list(d.items()):
                    logger.debug(f"⏿ checking {fileName}\t{json.dumps(fileHistory)}\t[{workerId}]")

                    if len(fileHistory) > 0:
                        if nowTime < fileHistory[-1].timestamp + assumeClosedSec:
                            # we can break because the list is ordered
                            logger.debug(
                                f"⎊\tbreaking early because {nowTime} < {fileHistory[-1].timestamp + assumeClosedSec}\t[{workerId}]"
                            )
                            break

                        else:
                            del d[fileName]
                            if fileProcessor is not None:
                                extraArgs = (
                                    fileProcessorKwargs
                                    if fileProcessorKwargs and isinstance(fileProcessorKwargs, dict)
                                    else {}
                                )
                                fileProcessor(
                                    fileName,
                                    **extraArgs,
                                )
                            logger.info(
                                f"🖄\tprocessed\t{fileName} at {(nowTime-fileHistory[-1].timestamp) if (fileHistory[-1].timestamp > 0) else 0} seconds\t[{workerId}]"
                            )

        time.sleep(1)
        logger.info(f"⛒\tfinished\t[{workerId}]")


def WatchAndProcessDirectory(
    directories,
    polling,
    fileProcessor,
    fileProcessorKwargs,
    assumeClosedSec,
    shuttingDown,
    logger,
):
    observer = PollingObserver() if polling else Observer()
    loggerToUse = logger if logger else logging
    handler = FileOperationEventHandler(
        logger=loggerToUse,
        polling=polling,
    )
    for directory in directories:
        loggerToUse.info(f"🗐\tScheduling {directory}")
        observer.schedule(handler, directory, recursive=True)

    observer.start()
    try:
        workerThreadCount = AtomicInt(value=0)
        ThreadPool(
            1,
            ProcessFileEventWorker(
                [
                    handler,
                    observer,
                    fileProcessor,
                    fileProcessorKwargs,
                    assumeClosedSec,
                    workerThreadCount,
                    shuttingDown,
                    loggerToUse,
                ],
            ),
        )

        while (not shuttingDown[0]) and observer.is_alive():
            observer.join(1)

        if shuttingDown[0]:
            raise WatchdogShutdown()

    except WatchdogShutdown:
        observer.unschedule_all()

    finally:
        observer.stop()
        observer.join()

    while workerThreadCount.value() > 0:
        time.sleep(1)