def concurrency
  :shared
end

def register(params)
  require 'date'
  require 'faraday'
  require 'fuzzystringmatch'
  require 'json'
  require 'lru_redux'

  # global enable/disable for this plugin based on environment variable(s)
  @netbox_enabled = (not [1, true, '1', 'true', 't', 'on', 'enabled'].include?(ENV["NETBOX_DISABLED"].to_s.downcase)) &&
                    [1, true, '1', 'true', 't', 'on', 'enabled'].include?(ENV["LOGSTASH_NETBOX_ENRICHMENT"].to_s.downcase)

  # source field containing lookup value
  @source = params["source"]

  # lookup type
  #   valid values are: ip_device, ip_vrf
  @lookup_type = params.fetch("lookup_type", "").to_sym

  # site value to include in queries for enrichment lookups, either specified directly or read from ENV
  @lookup_site = params["lookup_site"]
  _lookup_site_env = params["lookup_site_env"]
  if @lookup_site.nil? and !_lookup_site_env.nil?
    @lookup_site = ENV[_lookup_site_env]
  end
  if !@lookup_site.nil? && @lookup_site.empty? then
    @lookup_site = nil
  end

  # whether or not to enrich service for ip_device
  _lookup_service_str = params["lookup_service"]
  _lookup_service_env = params["lookup_service_env"]
  if _lookup_service_str.nil? and !_lookup_service_env.nil?
    _lookup_service_str = ENV[_lookup_service_env]
  end
  @lookup_service = [1, true, '1', 'true', 't', 'on', 'enabled'].include?(_lookup_service_str.to_s.downcase)
  @lookup_service_port_source = params.fetch("lookup_service_port_source", "[destination][port]")

  # API parameters
  @page_size = params.fetch("page_size", 50)

  # caching parameters
  @cache_size = params.fetch("cache_size", 1000)
  @cache_ttl = params.fetch("cache_ttl", 600)

  # target field to store looked-up value
  @target = params["target"]

  # verbose - either specified directly or read from ENV via verbose_env
  #   false - store the "name" (fallback to "display") and "id" value(s) as @target.name and @target.id
  #             e.g., (@target is destination.segment) destination.segment.name => ["foobar"]
  #                                                    destination.segment.id => [123]
  #   true - store a hash of arrays *under* @target
  #             e.g., (@target is destination.segment) destination.segment.name => ["foobar"]
  #                                                    destination.segment.id => [123]
  #                                                    destination.segment.url => ["whatever"]
  #                                                    destination.segment.foo => ["bar"]
  #                                                    etc.
  _verbose_str = params["verbose"]
  _verbose_env = params["verbose_env"]
  if _verbose_str.nil? and !_verbose_env.nil?
    _verbose_str = ENV[_verbose_env]
  end
  @verbose = [1, true, '1', 'true', 't', 'on', 'enabled'].include?(_verbose_str.to_s.downcase)

  # connection URL for netbox
  @netbox_url = params.fetch("netbox_url", "http://netbox:8080/netbox/api").delete_suffix("/")
  @netbox_url_suffix = "/netbox/api"
  @netbox_url_base = @netbox_url.delete_suffix(@netbox_url_suffix)

  # connection token (either specified directly or read from ENV via netbox_token_env)
  @netbox_token = params["netbox_token"]
  _netbox_token_env = params["netbox_token_env"]
  if @netbox_token.nil? and !_netbox_token_env.nil?
    @netbox_token = ENV[_netbox_token_env]
  end

  # hash of lookup types (from @lookup_type), each of which contains the respective looked-up values
  @cache_hash = LruRedux::ThreadSafeCache.new(params.fetch("lookup_cache_size", 512))

  # these are used for autopopulation only, not lookup/enrichment

  # autopopulate - either specified directly or read from ENV via autopopulate_env
  #   false - do not autopopulate netbox inventory when uninventoried devices are observed
  #   true - autopopulate netbox inventory when uninventoried devices are observed (not recommended)
  #
  # For now this is only done for devices/virtual machines, not for services or network segments.
  _autopopulate_str = params["autopopulate"]
  _autopopulate_env = params["autopopulate_env"]
  if _autopopulate_str.nil? and !_autopopulate_env.nil?
    _autopopulate_str = ENV[_autopopulate_env]
  end
  @autopopulate = [1, true, '1', 'true', 't', 'on', 'enabled'].include?(_autopopulate_str.to_s.downcase)

  # fields for device autopopulation
  @source_hostname = params["source_hostname"]
  @source_oui = params["source_oui"]
  @source_segment = params["source_segment"]

  # default manufacturer, device role and device type if not specified, either specified directly or read from ENVs
  @default_manuf = params["default_manuf"]
  _default_manuf_env = params["default_manuf_env"]
  if @default_manuf.nil? and !_default_manuf_env.nil?
    @default_manuf = ENV[_default_manuf_env]
  end
  if !@default_manuf.nil? && @default_manuf.empty? then
    @default_manuf = nil
  end

  if File.exist?(params.fetch("vm_oui_map_path", "/etc/vm_macs.yaml").to_s) then
    @vm_namesarray = Set.new
    YAML.safe_load(File.read(params["vm_oui_map_path"])).each do |mac|
      @vm_namesarray.add(mac['name'].to_s.downcase)
    end
  else
    @vm_namesarray = Set["pcs computer systems gmbh", "proxmox server solutions gmbh", "vmware, inc.", "xensource, inc."]
  end

  @default_dtype = params["default_dtype"]
  _default_dtype_env = params["default_dtype_env"]
  if @default_dtype.nil? and !_default_dtype_env.nil?
    @default_dtype = ENV[_default_dtype_env]
  end
  if !@default_dtype.nil? && @default_dtype.empty? then
    @default_dtype = nil
  end

  @default_drole = params["default_drole"]
  _default_drole_env = params["default_drole_env"]
  if @default_drole.nil? and !_default_drole_env.nil?
    @default_drole = ENV[_default_drole_env]
  end
  if !@default_drole.nil? && @default_drole.empty? then
    @default_drole = nil
  end

  # threshold for fuzzy string matching (for manufacturer, etc.)
  _autopopulate_fuzzy_threshold_str = params["autopopulate_fuzzy_threshold"]
  _autopopulate_fuzzy_threshold_str_env = params["autopopulate_fuzzy_threshold_env"]
  if _autopopulate_fuzzy_threshold_str.nil? and !_autopopulate_fuzzy_threshold_str_env.nil?
    _autopopulate_fuzzy_threshold_str = ENV[_autopopulate_fuzzy_threshold_str_env]
  end
  if _autopopulate_fuzzy_threshold_str.nil? || _autopopulate_fuzzy_threshold_str.empty? then
    @autopopulate_fuzzy_threshold = 0.75
  else
    @autopopulate_fuzzy_threshold = _autopopulate_fuzzy_threshold_str.to_f
  end

  # if the manufacturer is not found, should we create one or use @default_manuf?
  _autopopulate_create_manuf_str = params["autopopulate_create_manuf"]
  _autopopulate_create_manuf_env = params["autopopulate_create_manuf_env"]
  if _autopopulate_create_manuf_str.nil? and !_autopopulate_create_manuf_env.nil?
    _autopopulate_create_manuf_str = ENV[_autopopulate_create_manuf_env]
  end
  @autopopulate_create_manuf = [1, true, '1', 'true', 't', 'on', 'enabled'].include?(_autopopulate_create_manuf_str.to_s.downcase)

  # case-insensitive hash of OUIs (https://standards-oui.ieee.org/) to Manufacturers (https://demo.netbox.dev/static/docs/core-functionality/device-types/)
  @manuf_hash = LruRedux::ThreadSafeCache.new(params.fetch("manuf_cache_size", 2048))

  # end of autopopulation arguments

end

def filter(event)
  _key = event.get("#{@source}")
  if (not @netbox_enabled) || @lookup_type.nil? || @lookup_type&.empty? || _key.nil? || _key&.empty?
    return [event]
  end

  _url = @netbox_url
  _url_base = @netbox_url_base
  _url_suffix = @netbox_url_suffix
  _token = @netbox_token
  _page_size = @page_size
  _verbose = @verbose
  _lookup_type = @lookup_type
  _lookup_site = @lookup_site
  _lookup_service_port = (@lookup_service ? event.get("#{@lookup_service_port_source}") : nil).to_i
  _autopopulate = @autopopulate
  _autopopulate_hostname = @source_hostname
  _autopopulate_oui = @source_oui
  _autopopulate_segment = @source_segment
  _autopopulate_default_manuf = @default_manuf
  _autopopulate_default_drole = @default_drole
  _autopopulate_default_dtype = @default_dtype
  _autopopulate_fuzzy_threshold = @autopopulate_fuzzy_threshold
  _autopopulate_create_manuf = @autopopulate_create_manuf
  _result = @cache_hash.getset(_lookup_type){
              LruRedux::TTL::ThreadSafeCache.new(@cache_size, @cache_ttl)
            }.getset(_key){

              _nb = Faraday.new(_url) do |conn|
                conn.request :authorization, 'Token', _token
                conn.request :url_encoded
                conn.response :json, :parser_options => { :symbolize_names => true }
              end

              case _lookup_type
              #################################################################################
              when :ip_vrf
                # retrieve the list VRFs containing IP address prefixes containing the search key
                _vrfs = Array.new
                _query = {:contains => _key, :offset => 0, :limit => _page_size}
                _query[:site_n] = _lookup_site unless _lookup_site.nil? || _lookup_site&.empty?
                begin
                  while true do
                    if (_prefixes_response = _nb.get('ipam/prefixes/', _query).body) and _prefixes_response.is_a?(Hash) then
                      _tmp_prefixes = _prefixes_response.fetch(:results, [])
                      _tmp_prefixes.each do |p|
                        if (_vrf = p.fetch(:vrf, nil))
                          # non-verbose output is flatter with just names { :name => "name", :id => "id", ... }
                          # if _verbose, include entire object as :details
                          _vrfs << { :name => _vrf.fetch(:name, _vrf.fetch(:display, nil)),
                                     :id => _vrf.fetch(:id, nil),
                                     :site => ((_site = p.fetch(:site, nil)) && _site&.key?(:name)) ? _site[:name] : _site&.fetch(:display, nil),
                                     :tenant => ((_tenant = p.fetch(:tenant, nil)) && _tenant&.key?(:name)) ? _tenant[:name] : _tenant&.fetch(:display, nil),
                                     :url => p.fetch(:url, _vrf.fetch(:url, nil)),
                                     :details => _verbose ? _vrf.merge({:prefix => p.tap { |h| h.delete(:vrf) }}) : nil }
                        end
                      end
                      _query[:offset] += _tmp_prefixes.length()
                      break unless (_tmp_prefixes.length() >= _page_size)
                    else
                      break
                    end
                  end
                rescue Faraday::Error
                  # give up aka do nothing
                end
                collect_values(crush(_vrfs))

              #################################################################################
              when :ip_device
                # retrieve the list of IP addresses where address matches the search key, limited to "assigned" addresses.
                # then, for those IP addresses, search for devices pertaining to the interfaces assigned to each
                # IP address (e.g., ipam.ip_address -> dcim.interface -> dcim.device, or
                # ipam.ip_address -> virtualization.interface -> virtualization.virtual_machine)
                _devices = Array.new
                _query = {:address => _key, :offset => 0, :limit => _page_size}
                begin
                  while true do
                    if (_ip_addresses_response = _nb.get('ipam/ip-addresses/', _query).body) and _ip_addresses_response.is_a?(Hash) then
                      _tmp_ip_addresses = _ip_addresses_response.fetch(:results, [])
                      _tmp_ip_addresses.each do |i|
                        _is_device = nil
                        if (_obj = i.fetch(:assigned_object, nil)) && ((_device_obj = _obj.fetch(:device, nil)) || (_virtualized_obj = _obj.fetch(:virtual_machine, nil)))
                          _is_device = !_device_obj.nil?
                          _device = _is_device ? _device_obj : _virtualized_obj
                          # if we can, follow the :assigned_object's "full" device URL to get more information
                          _device = (_device.key?(:url) and (_full_device = _nb.get(_device[:url].delete_prefix(_url_base).delete_prefix(_url_suffix).delete_prefix("/")).body)) ? _full_device : _device
                          _device_id = _device.fetch(:id, nil)
                          _device_site = ((_site = _device.fetch(:site, nil)) && _site&.key?(:name)) ? _site[:name] : _site&.fetch(:display, nil)
                          next unless (_device_site.to_s.downcase == _lookup_site.to_s.downcase) || _lookup_site.nil? || _lookup_site&.empty? || _device_site.nil? || _device_site&.empty?
                          # look up service if requested (based on device/vm found and service port)
                          if (_lookup_service_port > 0) then
                            _services = Array.new
                            _service_query = { (_is_device ? :device_id : :virtual_machine_id) => _device_id, :port => _lookup_service_port, :offset => 0, :limit => _page_size }
                            while true do
                              if (_services_response = _nb.get('ipam/services/', _service_query).body) and _services_response.is_a?(Hash) then
                                _tmp_services = _services_response.fetch(:results, [])
                                _services.unshift(*_tmp_services) unless _tmp_services.nil? || _tmp_services&.empty?
                                _service_query[:offset] += _tmp_services.length()
                                break unless (_tmp_services.length() >= _page_size)
                              else
                                break
                              end
                            end
                            _device[:service] = _services
                          end
                          # non-verbose output is flatter with just names { :name => "name", :id => "id", ... }
                          # if _verbose, include entire object as :details
                          _devices << { :name => _device.fetch(:name, _device.fetch(:display, nil)),
                                        :id => _device_id,
                                        :url => _device.fetch(:url, nil),
                                        :service => _device.fetch(:service, []).map {|s| s.fetch(:name, s.fetch(:display, nil)) },
                                        :site => _device_site,
                                        :role => ((_role = _device.fetch(:role, _device.fetch(:device_role, nil))) && _role&.key?(:name)) ? _role[:name] : _role&.fetch(:display, nil),
                                        :cluster => ((_cluster = _device.fetch(:cluster, nil)) && _cluster&.key?(:name)) ? _cluster[:name] : _cluster&.fetch(:display, nil),
                                        :device_type => ((_dtype = _device.fetch(:device_type, nil)) && _dtype&.key?(:name)) ? _dtype[:name] : _dtype&.fetch(:display, nil),
                                        :manufacturer => ((_manuf = _device.dig(:device_type, :manufacturer)) && _manuf&.key?(:name)) ? _manuf[:name] : _manuf&.fetch(:display, nil),
                                        :details => _verbose ? _device : nil }
                        end
                      end
                      _query[:offset] += _tmp_ip_addresses.length()
                      break unless (_tmp_ip_addresses.length() >= _page_size)
                    else
                      # weird/bad response, bail
                      break
                    end
                  end # while true
                rescue Faraday::Error
                  # give up aka do nothing
                end

                if _autopopulate and (_query[:offset] == 0)
                  # no results found, autopopulate enabled, let's create an entry for this device

                  # match/look up manufacturer based on OUI
                  _autopopulate_manuf = nil
                  if !_autopopulate_oui.nil? && !_autopopulate_oui&.empty? then

                    # does it look like a VM or a regular device?
                    if @vm_namesarray.include?(_autopopulate_oui) then
                      # looks like this is probably a virtual machine
                      _autopopulate_manuf = { :name => _autopopulate_oui,
                                              :match => 1.0,
                                              :vm => true }

                    else
                      # looks like this is not a virtual machine (or we can't tell) so assume its' a regular device
                      _autopopulate_manuf = @manuf_hash.getset(_autopopulate_oui) {
                        _fuzzy_matcher = FuzzyStringMatch::JaroWinkler.create( :native )
                        _manufs = Array.new
                        # fetch the manufacturers to do the comparison. this is a lot of work
                        # and not terribly fast but once the hash it populated it shouldn't happen too often
                        _query = {:offset => 0, :limit => _page_size}
                        begin
                          while true do
                            if (_manufs_response = _nb.get('dcim/manufacturers/', _query).body) and _manufs_response.is_a?(Hash) then
                              _tmp_manufs = _manufs_response.fetch(:results, [])
                              _tmp_manufs.each do |_manuf|
                                _tmp_name = _manuf.fetch(:name, _manuf.fetch(:display, nil))
                                _manufs << { :name => _tmp_name,
                                             :id => _manuf.fetch(:id, nil),
                                             :url => _manuf.fetch(:url, nil),
                                             :match => _fuzzy_matcher.getDistance(_tmp_name.to_s.downcase, _autopopulate_oui.to_s.downcase),
                                             :vm => false
                                           }
                              end
                              _query[:offset] += _tmp_manufs.length()
                              break unless (_tmp_manufs.length() >= _page_size)
                            else
                              break
                            end
                          end
                        rescue Faraday::Error
                          # give up aka do nothing
                        end
                        # return the manuf with the highest match
                        !_manufs&.empty? ? _manufs.max_by{|k| k[:match] } : nil
                      }
                    end # virtual machine vs. regular device
                  end # _autopopulate_oui specified

                  if !_autopopulate_manuf.is_a?(Hash) then
                    # no match was found at ANY match level (empty database or no OUI specified), set default ("unspecified") manufacturer
                    _autopopulate_manuf = { :name => _autopopulate_default_manuf,
                                            :match => 0.0,
                                            :vm => false }
                  end

                  if _autopopulate_manuf[:vm] then
                    # todo: handle VM
                  else
                    # a regular non-vm device
                    if () and ()

                  end # virtual machine vs. regular device

                end # _autopopulate turned on and no results found

                _devices = collect_values(crush(_devices))
                _devices.fetch(:service, [])&.flatten!&.uniq!
                _devices

              #################################################################################
              else
                nil
              end
            }

  if !_result.nil? && _result.key?(:url) && !_result[:url]&.empty? then
    _result[:url].map! { |u| u.delete_prefix(@netbox_url_base).gsub('/api/', '/') }
    if (_lookup_type == :ip_device) && (!_result.key?(:device_type) || _result[:device_type]&.empty?) && _result[:url].any? { |u| u.include? "virtual-machines" } then
      _result[:device_type] = [ "Virtual Machine" ]
    end
  end
  event.set("#{@target}", _result) unless _result.nil? || _result&.empty?

  [event]
end

def mac_string_to_integer(string)
  string.tr('.:-','').to_i(16)
end

def collect_values(hashes)
  # https://stackoverflow.com/q/5490952
  hashes.reduce({}){ |h, pairs| pairs.each { |k,v| (h[k] ||= []) << v}; h }
end

def crush(thing)
  if thing.is_a?(Array)
    thing.each_with_object([]) do |v, a|
      v = crush(v)
      a << v unless [nil, [], {}, "", "Unspecified", "unspecified"].include?(v)
    end
  elsif thing.is_a?(Hash)
    thing.each_with_object({}) do |(k,v), h|
      v = crush(v)
      h[k] = v unless [nil, [], {}, "", "Unspecified", "unspecified"].include?(v)
    end
  else
    thing
  end
end

###############################################################################
# tests

###############################################################################