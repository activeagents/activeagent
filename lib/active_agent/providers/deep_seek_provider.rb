# DeepSeek, alias for the brand-cased service name resolution
#
# `service: "DeepSeek"` underscores to "deep_seek", so provider_load looks for
# this file. The provider itself lives in deepseek_provider.rb, which is also
# what `:deepseek` / "Deepseek" resolves to before the service-name remap.
require_relative "deepseek_provider"
