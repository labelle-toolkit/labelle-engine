# The spike behavior, Crystal edition (native-compiled family — Rust's
# sibling). Same shape: extern C declarations against contract.h, exported
# `fun`s the host calls. Mirrors behavior.lua / lib.rs exactly.

lib LibLabelle
  fun labelle_entity_create : UInt64
  fun labelle_component_set(id : UInt64, name : UInt8*, name_len : LibC::SizeT, json : UInt8*, json_len : LibC::SizeT)
  fun labelle_component_get(id : UInt64, name : UInt8*, name_len : LibC::SizeT, out : UInt8*, out_cap : LibC::SizeT) : LibC::SizeT
  fun labelle_event_emit(name : UInt8*, name_len : LibC::SizeT, json : UInt8*, json_len : LibC::SizeT)
  fun labelle_log(msg : UInt8*, len : LibC::SizeT)
  fun labelle_event_subscribe(name : UInt8*, name_len : LibC::SizeT)
  fun labelle_event_poll(out : UInt8*, out_cap : LibC::SizeT) : LibC::SizeT
end

module Script
  @@player : UInt64 = 0_u64

  def self.set(id : UInt64, name : String, json : String)
    LibLabelle.labelle_component_set(id, name.to_unsafe, name.bytesize, json.to_unsafe, json.bytesize)
  end

  def self.get(id : UInt64, name : String) : String
    buf = Bytes.new(192)
    len = LibLabelle.labelle_component_get(id, name.to_unsafe, name.bytesize, buf.to_unsafe, buf.size)
    String.new(buf[0, len])
  end

  def self.init
    @@player = LibLabelle.labelle_entity_create
    set(@@player, "Position", %({"x":0,"y":0}))
    LibLabelle.labelle_event_subscribe("tick_started".to_unsafe, "tick_started".bytesize)
    msg = "crystal: player #{@@player} ready"
    LibLabelle.labelle_log(msg.to_unsafe, msg.bytesize)
  end

  def self.update(_dt : Float32)
    # Receive side: drain the inbox the host filled before this tick.
    loop do
      buf = uninitialized UInt8[224]
      len = LibLabelle.labelle_event_poll(buf.to_unsafe, 224)
      break if len == 0
      ev = String.new(buf.to_unsafe, len)
      if ev.includes?(%("n":4))
        set(@@player, "TickLog", %({"last":4}))
        msg = "crystal: saw tick 4"
        LibLabelle.labelle_log(msg.to_unsafe, msg.bytesize)
      end
    end

    json = get(@@player, "Position")
    # Parse `"x":<n>` manually. POC FINDING: `to_i64?(strict: false)`
    # raises-and-rescues internally, and Crystal's raise captures a
    # backtrace by walking the stack — including the host's foreign Zig
    # frames — which segfaults under embedding. Script entry points must
    # avoid raising APIs (or the plugin compiles with callstack capture
    # disabled); see the README's Crystal notes.
    tail = json.split(%("x":))[1]? || "0"
    x = 0_i64
    tail.each_char do |c|
      break unless c.ascii_number?
      x = x * 10 + (c.ord - 48)
    end
    x += 10
    set(@@player, "Position", %({"x":#{x},"y":0}))
    if x == 30
      bullet = LibLabelle.labelle_entity_create
      set(bullet, "Bullet", %({"vx":0,"vy":-500}))
      ev = %({"owner":#{@@player}})
      LibLabelle.labelle_event_emit("bullet_spawned".to_unsafe, "bullet_spawned".bytesize, ev.to_unsafe, ev.bytesize)
      msg = "crystal: bullet away"
      LibLabelle.labelle_log(msg.to_unsafe, msg.bytesize)
    end
  end
end

fun crystal_script_init : Void
  Script.init
end

fun crystal_script_update(dt : Float32) : Void
  Script.update(dt)
end

# Embedding seam: the host calls this ONCE before any script fn — it
# initializes the GC and runs Crystal's top-level (the documented
# embed-Crystal-as-a-library pattern), replacing the `main` the object
# file ships (which the build localizes away).
fun crystal_script_boot : Void
  Crystal.init_runtime
  # Embedded-mode mitigation for the POC: the host owns the stack, and
  # bdw-gc's first collection under a foreign stack is the known sharp
  # edge — disabling collection sidesteps it here. The real labelle-crystal
  # registers the host stack bounds with the GC instead (documented in
  # the README as the plugin's first work item).
  GC.disable
end
