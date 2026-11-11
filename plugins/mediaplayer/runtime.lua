-- Native library discovery for the Media Player plugin.
local config = require "core.config"

---@class plugins.mediaplayer.runtime
---@field path string? Path or loader name of the selected native library
local runtime = {}
local directory = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./"
local ffi, cached, cached_override

---Load FFI only when playback is requested, preserving non-LuaJIT editor startup.
local function initialize_ffi()
  if ffi then return end
  local ok, module = pcall(require, "ffi")
  if not ok then error("Media Player requires LuaJIT with FFI support.", 0) end
  ffi = module
  ffi.cdef [[ unsigned long mpv_client_api_version(void); ]]
  if pcall(ffi.typeof, "pragtical_media_owner") then return end
  ffi.cdef [[
    typedef struct mpv_handle pragtical_media_handle;
    typedef struct mpv_render_context pragtical_media_context;
    typedef struct { int type; void *data; } pragtical_media_param;
    typedef struct {
      int event_id; int error; uint64_t reply_userdata; void *data;
    } pragtical_media_event;
    typedef struct { const char *name; int format; void *data; } pragtical_media_property;
    typedef struct { int reason; int error; } pragtical_media_end;
    typedef struct {
      pragtical_media_handle *handle;
      pragtical_media_context *context;
    } pragtical_media_owner;
    pragtical_media_handle *mpv_create(void);
    int mpv_set_option_string(pragtical_media_handle *, const char *, const char *);
    int mpv_initialize(pragtical_media_handle *);
    int mpv_command_async(pragtical_media_handle *, uint64_t, const char **);
    int mpv_observe_property(pragtical_media_handle *, uint64_t, const char *, int);
    pragtical_media_event *mpv_wait_event(pragtical_media_handle *, double);
    const char *mpv_error_string(int);
    int mpv_render_context_create(pragtical_media_context **,
      pragtical_media_handle *, pragtical_media_param *);
    uint64_t mpv_render_context_update(pragtical_media_context *);
    int mpv_render_context_render(pragtical_media_context *, pragtical_media_param *);
    void mpv_render_context_free(pragtical_media_context *);
    void mpv_terminate_destroy(pragtical_media_handle *);
    int mpv_pragtical_audio_capture(pragtical_media_handle *, int);
    int mpv_pragtical_audio_samples(pragtical_media_handle *, float *, int,
      int *, int *, uint64_t *);
  ]]
end

---Load an explicit override, bundled runtime, or system library, in that order.
---An explicit override is exclusive; automatic discovery skips unusable binaries.
---@return ffi.namespace library Compatible libmpv client and software-render API
---@return table ffi LuaJIT FFI module
function runtime.load()
  initialize_ffi()
  local override = config.plugins.mediaplayer.library
  if cached and cached_override == override then return cached, ffi end
  local cpu = ({x64 = "x86_64", arm64 = "aarch64", x86 = "i686"})[ffi.arch] or ffi.arch
  local arch = ARCH or cpu .. "-" .. (ffi.os == "OSX" and "darwin" or ffi.os:lower())
  local suffix = ffi.os == "Windows" and ".dll" or ".so"
  local candidates
  if override and override ~= "" then
    candidates = {override}
  else
    candidates = {
      directory .. "mpv." .. arch .. suffix,
      directory .. "mpv" .. suffix,
      directory .. "libmpv" .. suffix,
      directory .. "libmpv.dylib"
    }
    local system_names = ffi.os == "Windows" and {"mpv-2.dll", "libmpv-2.dll", "mpv"}
      or ffi.os == "OSX" and {"mpv", "libmpv.2.dylib", "/opt/homebrew/lib/libmpv.2.dylib", "/usr/local/lib/libmpv.2.dylib"}
      or {"mpv", "libmpv.so.2"}
    for _, name in ipairs(system_names) do candidates[#candidates + 1] = name end
  end
  local errors = {}
  for _, name in ipairs(candidates) do
    local ok, library = pcall(function()
      local result = ffi.load(name)
      local version = tonumber(result.mpv_client_api_version())
      assert(math.floor(version / 65536) == 2, "libmpv client API version 2 is required")
      for _, symbol in ipairs({"mpv_create", "mpv_initialize", "mpv_set_option_string",
        "mpv_command_async", "mpv_observe_property", "mpv_wait_event", "mpv_error_string",
        "mpv_render_context_create", "mpv_render_context_update", "mpv_render_context_render",
        "mpv_render_context_free", "mpv_terminate_destroy"}) do
        assert(result[symbol], "Missing libmpv symbol: " .. symbol)
      end
      return result
    end)
    if ok then
      cached, cached_override, runtime.path = library, override, name
      return library, ffi
    end
    errors[#errors + 1] = name .. ": " .. tostring(library)
  end
  error("Media Player could not load libmpv. Install its runtime through PPM, "
    .. "install system libmpv, or set the library path in Settings.\n"
    .. table.concat(errors, "\n"), 0)
end

return runtime
