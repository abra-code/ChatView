# Consumer ProGuard rules for com.abracode:chatview.
#
# The library ships no reflection-based entry points of its own; kotlinx-serialization's generated serializers
# are referenced statically from the ported codecs, so no keep rules are required yet. RichText and
# AsyncImageCache contribute their own consumer rules through the dependency graph.
