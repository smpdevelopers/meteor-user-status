###
  Apparently, the new api.export takes care of issues here. No need to attach to global namespace.
  See http://shiggyenterprises.wordpress.com/2013/09/09/meteor-packages-in-coffeescript-0-6-5/

  We may want to make UserSessions a server collection to take advantage of indices.
  Will implement if someone has enough online users to warrant it.
###
UserConnections = new Meteor.Collection("user_status_sessions", { connection: null })

statusEvents = new (Npm.require('events').EventEmitter)()

###
  Multiplex login/logout events to status.online
###
statusEvents.on "connectionLogin", (advice) ->
  Meteor.users.update advice.userId,
    $set:
      'status.online': true,
      'status.lastLogin': advice.loginTime
  return

statusEvents.on "connectionLogout", (advice) ->
  conns = UserConnections.find(userId: advice.userId).fetch()
  if conns.length is 0
    # Go offline if we are the last connection for this user
    # This includes removing all idle information
    Meteor.users.update advice.userId,
      $set: {'status.online': false }
      $unset:
        'status.idle': null
        'status.lastActivity': null
  else if _.every(conns, (c) -> c.idle)
    ###
      If the last active connection quit, then we should go idle with the most recent activity

      If the most recently active idle connection quit, we shouldn't tick the value backwards.
      TODO this may result in a no-op so maybe we can skip the update.
    ###
    lastActivity = _.max(_.pluck conns, "lastActivity")
    lastActivity = Math.max(lastActivity, advice.lastActivity) if advice.lastActivity?
    Meteor.users.update advice.userId,
      $set:
        'status.idle': true
        'status.lastActivity': lastActivity
  return

###
  Multiplex idle/active events to status.idle
  TODO: Hopefully this is quick because it's all in memory, but we can use indices if it turns out to be slow

  TODO: There is a race condition when switching between tabs, leaving the user inactive while idle goes from one tab to the other.
  It can probably be smoothed out.
###
statusEvents.on "connectionIdle", (advice) ->
  conns = UserConnections.find(userId: advice.userId).fetch()
  return unless _.every(conns, (c) -> c.idle)
  # Set user to idle if all the connections are idle
  # This will not be the most recent idle across a disconnection, so we use max

  # TODO: the race happens here where everyone was idle when we looked for them but now one of them isn't.
  Meteor.users.update advice.userId,
    $set:
      'status.idle': true
      'status.lastActivity': _.max(_.pluck conns, "lastActivity")
  return

statusEvents.on "connectionActive", (advice) ->
  Meteor.users.update advice.userId,
    $unset:
      'status.idle': null
      'status.lastActivity': null
  return

# Clear any online users on startup (they will re-add themselves)
# Having no status.online is equivalent to status.online = false (above)
# but it is unreasonable to set the entire users collection to false on startup.
Meteor.startup ->
  Meteor.users.update {}
  , $unset: {
    "status.online": null
    "status.idle": null
    "status.lastActivity": null
  }
  , {multi: true}

###
  Local session modifification functions - also used in testing
###

addSession = (userId, connectionId, timestamp, ipAddr, device) ->
  UserConnections.upsert connectionId,
    $set: {
      userId: userId
      ipAddr: ipAddr
      loginTime: timestamp
      device: device
    }

  statusEvents.emit "connectionLogin",
    userId: userId
    connectionId: connectionId
    ipAddr: ipAddr
    loginTime: timestamp
  return

removeSession = (userId, connectionId, timestamp) ->
  conn = UserConnections.findOne(connectionId)
  UserConnections.remove(connectionId)

  # Don't emit this again if the connection was already closed
  return unless conn?

  statusEvents.emit "connectionLogout",
    userId: userId
    connectionId: connectionId
    lastActivity: conn?.lastActivity # If this connection was idle, pass the last activity we saw
    logoutTime: timestamp
  return

idleSession = (userId, connectionId, timestamp) ->
  UserConnections.update connectionId,
    $set: {
      idle: true
      lastActivity: timestamp
    }

  statusEvents.emit "connectionIdle",
    userId: userId
    connectionId: connectionId
    lastActivity: timestamp
  return

activeSession = (userId, connectionId, timestamp) ->
  UserConnections.update connectionId,
    $set: { idle: false }
    $unset: { lastActivity: null }

  statusEvents.emit "connectionActive",
    userId: userId
    connectionId: connectionId
    lastActivity: timestamp
  return

###
   Connected device detection
###

detectDevice = (userAgent) ->
  userAgent = userAgent.toLowerCase()

  deviceTypes = [
    "tv"
    "tablet"
    "mobile"
    "desktop"
  ]

  device =
    type: ""
    model: ""

  test = (regex) -> regex.test(userAgent)
  exec = (regex) -> regex.exec(userAgent)

  if test(/googletv|smarttv|internet.tv|netcast|nettv|appletv|boxee|kylo|roku|dlnadoc|ce\-html/)
    # Check if user agent is a smart tv
    device.type = deviceTypes[0]
    device.model = "smartTv"

  else if test(/xbox|playstation.3|wii/)
    # Check if user agent is a game console
    device.type = deviceTypes[0]
    device.model = "gameConsole"

  else if test(/ip(a|ro)d/)
    # Check if user agent is a iPad
    device.type = deviceTypes[1]
    device.model = "ipad"

  else if (test(/tablet/) and not test(/rx-34/)) or test(/folio/)
    # Check if user agent is a Tablet
    device.type = deviceTypes[1]
    device.model = String(exec(/playbook/) or "")

  else if test(/linux/) and test(/android/) and not test(/fennec|mobi|htc.magic|htcX06ht|nexus.one|sc-02b|fone.945/)
    # Check if user agent is an Android Tablet
    device.type = deviceTypes[1]
    device.model = "android"

  else if test(/kindle/) or (test(/mac.os/) and test(/silk/))
    # Check if user agent is a Kindle or Kindle Fire
    device.type = deviceTypes[1]
    device.model = "kindle"

  else if test(/gt-p10|sc-01c|shw-m180s|sgh-t849|sch-i800|shw-m180l|sph-p100|sgh-i987|zt180|htc(.flyer|\_flyer)|sprint.atp51|viewpad7|pandigital(sprnova|nova)|ideos.s7|dell.streak.7|advent.vega|a101it|a70bht|mid7015|next2|nook/) or (test(/mb511/) and test(/rutem/))
    # Check if user agent is a pre Android 3.0 Tablet
    device.type = deviceTypes[1]
    device.model = "android"

  else if test(/bb10/)
    # Check if user agent is a BB10 device
    device.type = deviceTypes[1]
    device.model = "blackberry"

  else
    # Check if user agent is one of common mobile types
    device.model = exec(/iphone|ipod|android|blackberry|opera mini|opera mobi|skyfire|maemo|windows phone|palm|iemobile|symbian|symbianos|fennec|j2me/);

    if device.model isnt null
      device.type = deviceTypes[2]
      device.model = String(device.model)
    else
      device.model = ""

      if test(/bolt|fennec|iris|maemo|minimo|mobi|mowser|netfront|novarra|prism|rx-34|skyfire|tear|xv6875|xv6975|google.wireless.transcoder/)
        # Check if user agent is unique Mobile User Agent
        device.type = deviceTypes[2]

      else if test(/opera/) and test(/windows.nt.5/) and test(/htc|xda|mini|vario|samsung\-gt\-i8000|samsung\-sgh\-i9/)
        # Check if user agent is an odd Opera User Agent - http://goo.gl/nK90K
        device.type = deviceTypes[2]

      else if (test(/windows.(nt|xp|me|9)/) and not test(/phone/)) or test(/win(9|.9|nt)/) or test(/\(windows 8\)/)
        # Check if user agent is Windows Desktop, "(Windows 8)" Chrome extra exception
        device.type = deviceTypes[3]

      else if test(/macintosh|powerpc/) and not test(/silk/)
        # Check if agent is Mac Desktop
        device.type = deviceTypes[3]
        device.model = "mac";

      else if test(/linux/) and test(/x11/)
        # Check if user agent is a Linux Desktop
        device.type = deviceTypes[3]

      else if test(/solaris|sunos|bsd/)
        # Check if user agent is a Solaris, SunOS, BSD Desktop
        device.type = deviceTypes[3]

      else if test(/bot|crawler|spider|yahoo|ia_archiver|covario-ids|findlinks|dataparksearch|larbin|mediapartners-google|ng-search|snappy|teoma|jeeves|tineye/) and not test(/mobile/)
        # Check if user agent is a Desktop BOT/Crawler/Spider
        device.type = deviceTypes[3]
        device.model = "crawler"

      else
        # Otherwise assume it is a Mobile Device
        device.type = deviceTypes[2]

  return device

# pub/sub trick as referenced in http://stackoverflow.com/q/10257958/586086
# TODO: replace this with Meteor.onConnection and login hooks.

Meteor.publish null, ->
  timestamp = Date.now() # compute this as early as possible
  userId = @_session.userId
  return unless @_session.socket? # Or there is nothing to close!

  connection = @_session.connectionHandle
  connectionId = @_session.id # same as connection.id
  device = detectDevice(@connection.httpHeaders['user-agent']);

  # Untrack connection on logout
  unless userId?
    # TODO: this could be replaced with a findAndModify once it's supported on Collections
    existing = UserConnections.findOne(connectionId)
    return unless existing? # Probably new session

    removeSession(existing.userId, connectionId, timestamp)
    return

  # Add socket to open connections
  addSession(userId, connectionId, timestamp, connection.clientAddress, device)

  # Remove socket on close
  @_session.socket.on "close", Meteor.bindEnvironment ->
    removeSession(userId, connectionId, Date.now())
  , (e) ->
    Meteor._debug "Exception from connection close callback:", e
  return

# TODO the below methods only care about logged in users.
# We can extend this to all users. (See also client code)
# We can trust the timestamp here because it was sent from a TimeSync value.
Meteor.methods
  "user-status-idle": (timestamp) ->
    return unless @userId
    idleSession(@userId, @connection.id, timestamp)
    return

  "user-status-active": (timestamp) ->
    return unless @userId
    # We only use timestamp because it's when we saw activity *on the client*
    # as opposed to just being notified it.
    # It is probably more accurate even if a few hundred ms off
    # due to how long the message took to get here.
    activeSession(@userId, @connection.id, timestamp)
    return

# Exported variable
UserStatus =
  connections: UserConnections
  events: statusEvents

# Internal functions, exported for testing
StatusInternals =
  addSession: addSession
  removeSession: removeSession
  idleSession: idleSession
  activeSession: activeSession
