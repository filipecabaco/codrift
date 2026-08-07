# Dialyzer warnings we deliberately accept.
#
# Francis' `ws/3` and `sse/3` macros compile the handler function into a
# generated module (reported as "nofile"). Inside that module the handler is
# only ever *directly* applied as `handler.({:received, msg}, state)`; the
# `:join` and `{:close, _}` events are dispatched indirectly, via
# `Francis.Websocket.call_join/2` and `call_close/3`. Dialyzer only sees the
# direct call site, so it concludes the `:join` clause of every handler is
# unreachable and emits a `pattern_match` warning against it.
#
# It is a false positive: `Francis.Websocket.init/1` sends `:__francis_join__`
# to itself, `handle_info/2` routes that to `call_join/2`, and
# test/codrift/web/transport_e2e_test.exs asserts over a real socket that the
# `{"event":"connected"}` frame — produced only by our `:join` clause — arrives.
#
# Scoped to "nofile" so it cannot hide warnings in our own source files.
[
  {"nofile", :pattern_match}
]
