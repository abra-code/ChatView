# Consumer ProGuard rules for com.abracode:chatview-acp.
#
# The module ships no reflection-based entry points of its own; kotlinx-serialization's generated serializers are
# referenced statically and every wire payload is parsed through kotlinx JsonObject rather than reflectively.
# OkHttp contributes its own consumer rules through the dependency graph.
