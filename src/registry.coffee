somata = require 'somata'
{log} = somata

VERBOSE = process.env.SOMATA_VERBOSE || false
SERVICE_HOST = process.env.SOMATA_SERVICE_HOST
REGISTRY_PORT = process.env.SOMATA_REGISTRY_PORT || 8420
DEFAULT_HEARTBEAT = 5000
BUMP_FACTOR = 1.5 # Wiggle room for heartbeats

# Nested map of Name -> ID -> Instance
registered = {}

# Map of ID -> Expected heartbeat
heartbeats = {}

# Registration

registerService = (client_id, service_instance, cb) ->
    service_name = service_instance.name
    service_instance.client_id = client_id
    service_id = service_instance.id
    registered[service_name] ||= {}
    registered[service_name][service_id] = service_instance
    heartbeat_interval = service_instance.heartbeat
    if !heartbeat_interval? then heartbeat_interval = DEFAULT_HEARTBEAT
    heartbeats[client_id] = new Date().getTime() + heartbeat_interval * 1.5
    log.s "Registered #{service_id}"
    cb null, service_instance

deregisterService = (service_name, service_id, cb) ->
    log.w "Deregistering #{service_id}"
    if service_instance = registered[service_name]?[service_id]
        delete registry.known_pings[service_instance.client_id]
        delete registered[service_name]?[service_id]
        registry.publish 'deregister', service_instance
    cb? null, service_id

# Health checking

isHealthy = (service_instance) ->
    if service_instance.heartbeat == 0 then return true
    next_heartbeat = heartbeats[service_instance.client_id]
    is_healthy = next_heartbeat > new Date().getTime()
    if !is_healthy
        log.w "Heartbeat overdue by #{new Date().getTime() - next_heartbeat}" if VERBOSE
        deregisterService service_instance.name, service_instance.id
    return is_healthy

checkServices = ->
    for service_name, service_instances of registered
        for service_id, service_instance of service_instances
            isHealthy service_instance

setInterval checkServices, 2000

# Finding services

findServices = (cb) ->
    cb null, registered

getHealthyServiceByName = (service_name) ->
    service_instances = registered[service_name]
    # TODO: Go through to find healthy ones
    for service_id, instance of service_instances
        if isHealthy instance
            return instance
    return null

getServiceById = (service_id) ->
    service_name = service_id.split('~')[0]
    return registered[service_name]?[service_id]

getServiceByClientId = (client_id) ->
    for service_name, service_instances of registered
        for service_id, instance of service_instances
            if instance.client_id == client_id
                return instance
    return null

getService = (service_name, cb) ->
    if service_instance = getHealthyServiceByName(service_name)
        cb null, service_instance
    else
        log.w "No healthy instances for #{service_name}"
        cb "No healthy instances for #{service_name}"

# Heartbeat responses

registry_methods = {
    registerService
    deregisterService
    findServices
    getService
}

registry_options = {
    rpc_options: {port: REGISTRY_PORT}
}

class Registry extends somata.Service

    register: ->
        log.d "[Registry.register] Who registers the registry?"

    deregister: (cb) ->
        cb()

    handleMethod: (client_id, message) ->
        if message.method == 'registerService'
            registerService client_id, message.args..., (err, response) =>
                @sendResponse client_id, message.id, response
        else
            super

    gotPing: (client_id) ->
        if service_instance = getServiceByClientId client_id
            heartbeat_interval = service_instance.heartbeat
            if !heartbeat_interval? then heartbeat_interval = DEFAULT_HEARTBEAT
            heartbeats[client_id] = new Date().getTime() + heartbeat_interval * 1.5

registry = new Registry 'somata:registry', registry_methods, registry_options

