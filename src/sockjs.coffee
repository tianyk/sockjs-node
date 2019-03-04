# ***** BEGIN LICENSE BLOCK *****
# Copyright (c) 2011-2012 VMware, Inc.
#
# For the license see COPYING.
# ***** END LICENSE BLOCK *****
# 入口

events = require('events')
fs = require('fs')
webjs = require('./webjs')
utils = require('./utils')

trans_websocket = require('./trans-websocket')
trans_jsonp = require('./trans-jsonp')
trans_xhr = require('./trans-xhr')
iframe = require('./iframe')
trans_eventsource = require('./trans-eventsource')
trans_htmlfile = require('./trans-htmlfile')
chunking_test = require('./chunking-test')

sockjsVersion = ->
    try
        pkg = fs.readFileSync(__dirname + '/../package.json', 'utf-8')
    catch x
    return if pkg then JSON.parse(pkg).version else null


class App extends webjs.GenericApp
    # /${prefix}/ 主页
    welcome_screen: (req, res) ->
        res.setHeader('content-type', 'text/plain; charset=UTF-8')
        res.writeHead(200)
        res.end("Welcome to SockJS!\n")
        return true
    # /${prefix}/404 404界面
    handle_404: (req, res) ->
        res.setHeader('content-type', 'text/plain; charset=UTF-8')
        res.writeHead(404)
        res.end('404 Error: Page not found\n')
        return true

    disabled_transport: (req, res, data) ->
        return @handle_404(req, res, data)

    # 如果 jsessionid 为true 会读取 JSESSIONID 并且每次重新设置。设置sessionId 
    h_sid: (req, res, data) ->
        # Some load balancers do sticky sessions, but only if there is
        # a JSESSIONID cookie. If this cookie isn't yet set, we shall
        # set it to a dummy value. It doesn't really matter what, as
        # session information is usually added by the load balancer.
        req.cookies = utils.parseCookie(req.headers.cookie)
        if typeof @options.jsessionid is 'function'
            # Users can supply a function
            @options.jsessionid(req, res)
        else if (@options.jsessionid and res.setHeader)
            # We need to set it every time, to give the loadbalancer
            # opportunity to attach its own cookies.
            jsid = req.cookies['JSESSIONID'] or 'dummy'
            res.setHeader('Set-Cookie', 'JSESSIONID=' + jsid + '; path=/')
        return data

    log: (severity, line) ->
        @options.log(severity, line)


# 扩展了.iframe方法
utils.objectExtend(App.prototype, iframe.app)
utils.objectExtend(App.prototype, chunking_test.app)

# 扩展了 sockjs_websocket raw_websocket 方法
utils.objectExtend(App.prototype, trans_websocket.app)
# 扩展了 jsonp 和 jsonp_send 方法
utils.objectExtend(App.prototype, trans_jsonp.app)
utils.objectExtend(App.prototype, trans_xhr.app)
utils.objectExtend(App.prototype, trans_eventsource.app)
utils.objectExtend(App.prototype, trans_htmlfile.app)


# 路由器
generate_dispatcher = (options) ->
        # 正则路由匹配 prefix 
        p = (s) => new RegExp('^' + options.prefix + s + '[/]?$')
        t = (s) => [p('/([^/.]+)/([^/.]+)' + s), 'server', 'session']
        opts_filters = (options_filter='xhr_options') ->
            return ['h_sid', 'xhr_cors', 'cache_for', options_filter, 'expose']

        # 第三个参数为中间件链条
        prefix_dispatcher = [
            # ${prefix}
            ['GET',     p(''), ['welcome_screen']],
            # ${prefix}/iframe.html
            ['GET',     p('/iframe[0-9-.a-z_]*.html'), ['iframe', 'cache_for', 'expose']],
            # OPTIONS ${prefix}/info 
            ['OPTIONS', p('/info'), opts_filters('info_options')],
            # ${prefix}/info 
            ['GET',     p('/info'), ['xhr_cors', 'h_no_cache', 'info', 'expose']],
            # OPTIONS ${prefix}/chunking_test 
            ['OPTIONS', p('/chunking_test'), opts_filters()],
            # ${prefix}/chunking_test 
            ['POST',    p('/chunking_test'), ['xhr_cors', 'expect_xhr', 'chunking_test']]
        ]
        # 传输协议路由
        transport_dispatcher = [
            ['GET',     t('/jsonp'), ['h_sid', 'h_no_cache', 'jsonp']],
            ['POST',    t('/jsonp_send'), ['h_sid', 'h_no_cache', 'expect_form', 'jsonp_send']],
            ['POST',    t('/xhr'), ['h_sid', 'h_no_cache', 'xhr_cors', 'xhr_poll']],
            ['OPTIONS', t('/xhr'), opts_filters()],
            ['POST',    t('/xhr_send'), ['h_sid', 'h_no_cache', 'xhr_cors', 'expect_xhr', 'xhr_send']],
            ['OPTIONS', t('/xhr_send'), opts_filters()],
            ['POST',    t('/xhr_streaming'), ['h_sid', 'h_no_cache', 'xhr_cors', 'xhr_streaming']],
            ['OPTIONS', t('/xhr_streaming'), opts_filters()],
            ['GET',     t('/eventsource'), ['h_sid', 'h_no_cache', 'eventsource']],
            ['GET',     t('/htmlfile'),    ['h_sid', 'h_no_cache', 'htmlfile']],
        ]

        # 是否开启 websocket 协议
        # TODO: remove this code on next major release
        if options.websocket
            prefix_dispatcher.push(
                ['GET', p('/websocket'), ['raw_websocket']])
            transport_dispatcher.push(
                ['GET', t('/websocket'), ['sockjs_websocket']])
        else
            # modify urls to return 404
            prefix_dispatcher.push(
                ['GET', p('/websocket'), ['cache_for', 'disabled_transport']])
            transport_dispatcher.push(
                ['GET', t('/websocket'), ['cache_for', 'disabled_transport']])
        return prefix_dispatcher.concat(transport_dispatcher)

class Listener
    constructor: (@options, emit) ->
        @app = new App()
        @app.options = @options
        @app.emit = emit
        @app.log('debug', 'SockJS v' + sockjsVersion() + ' ' +
                          'bound to ' + JSON.stringify(@options.prefix))
        @dispatcher = generate_dispatcher(@options)
        @webjs_handler = webjs.generateHandler(@app, @dispatcher)
        @path_regexp = new RegExp('^' + @options.prefix  + '([/].+|[/]?)$')

    handler: (req, res, extra) =>
        # All urls that match the prefix must be handled by us.
        if not req.url.match(@path_regexp)
            return false
        @webjs_handler(req, res, extra)
        return true

    getHandler: () ->
        return (a,b,c) => @handler(a,b,c)


class Server extends events.EventEmitter
    constructor: (user_options) ->
        @options =
            prefix: ''
            # 部分协议
            response_limit: 128*1024
            # 如果为 false 禁用 websocket 协议
            websocket: true
            faye_server_options: null
            jsessionid: false
            heartbeat_delay: 25000
            disconnect_delay: 5000
            log: (severity, line) -> console.log(line)
            sockjs_url: 'https://cdn.jsdelivr.net/sockjs/1/sockjs.min.js'
        if user_options
            utils.objectExtend(@options, user_options)

    listener: (handler_options) ->
        options = utils.objectExtend({}, @options)
        if handler_options
            utils.objectExtend(options, handler_options)
        return new Listener(options, => @emit.apply(@, arguments))

    installHandlers: (http_server, handler_options) ->
        handler = @listener(handler_options).getHandler()
        utils.overshadowListeners(http_server, 'request', handler)
        utils.overshadowListeners(http_server, 'upgrade', handler)
        return true

    middleware: (handler_options) ->
        handler = @listener(handler_options).getHandler()
        handler.upgrade = handler
        return handler

# 获取一个 sockServer 对象
exports.createServer = (options) ->
    return new Server(options)

# 先创建一个 sockServer 对象，然后 installHandlers 初始化 
exports.listen = (http_server, options) ->
    srv = exports.createServer(options)
    if http_server
        srv.installHandlers(http_server)
    return srv
