// LED ring (+ logo) of the Station Midi (24 + 6 RGB) and Lite 2 (3 RGB, no logo); layout per Model.
//
// How the hardware is driven: the LEDs sit behind kernel LED triggers that expose them as
// framebuffers (Midi: "ledfb-ring"/"ledfb-logo" -> /dev/fb0 "ring" 24x1, /dev/fb1 "logo" 6x1;
// Lite 2: "led_ring_fb" -> /dev/fb0 "YNDX LED ring" 3x1), 24 bpp, rgba 8/16,8/8,8/0 -> bytes per
// pixel are B,G,R; pixel i = the i-th sysfs LED of the strip.
// On the Midi a pwrite() is only shown on the next write or FBIOPAN_DISPLAY (the ledfb driver
// pushes the framebuffer at the *start* of each write/pan), so every frame is pwrite() +
// FBIOPAN_DISPLAY. Cost ~2.5 ms per ring update (i2c), far cheaper than per-LED sysfs writes.
// If the framebuffers are missing or the triggers are not active, we fall back to the
// per-channel sysfs brightness files kept open.
//
// Ring index order: Yandex patterns (ledpatterns/ring/*.led, one RRGGBB column per LED) anchor
// their animations at the first LED and grow symmetrically to its neighbours (mute.led,
// alice_thinking.led), so LED 0 is the "home" position; all animations here are relative to it
// and go towards increasing indices.
#include <fcntl.h>
#include <linux/fb.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <cmath>
#include <cstring>
#include <vector>

#include "core/log.h"
#include "hw/ambient.h"
#include "hw/hw.h"
#include "hw/sysfs.h"

namespace cs {

namespace {

constexpr int kFrameMs = 33;          // ~30 fps while animating
constexpr float kMaxScale = 0.8f;     // global cap: never drive LEDs above 80 % PWM
constexpr int64_t kVolumeShowMs = 1500;
constexpr int64_t kSwipeShowMs = 700;  // one comet lap for a track change
constexpr int64_t kHoldShowMs = 900;   // action-button hold: one smooth fade-in/fade-out
constexpr int64_t kCommandShowMs = 500;  // voice command: one short full-ring flash
constexpr int64_t kThinkWaveMs = 1400;  // assistant "thinking" ripple period
constexpr int64_t kSpeakWaveMs = 900;   // assistant answer ripple period
constexpr int64_t kWarnEveryMs = 10000;  // rate limit for repeated per-frame write warnings
constexpr const char *kLedDir = "/sys/class/leds/";

struct Col {
  float r = 0, g = 0, b = 0;
};

Col operator*(Col c, float k) { return {c.r * k, c.g * k, c.b * k}; }
Col rgb(int r, int g, int b) { return {r / 255.f, g / 255.f, b / 255.f}; }

Col hsv(float h, float s, float v) {
  h = std::fmod(h, 1.f);
  if (h < 0) h += 1.f;
  float i = std::floor(h * 6), f = h * 6 - i, p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s);
  switch (int(i) % 6) {
    case 0: return {v, t, p};
    case 1: return {q, v, p};
    case 2: return {p, v, t};
    case 3: return {p, q, v};
    case 4: return {t, p, v};
    default: return {v, p, q};
  }
}

// Smooth 0..1 oscillation with period ms, starting at minimum.
float wave(int64_t t, int64_t period) { return 0.5f - 0.5f * std::cos(float(t % period) / float(period) * 6.2831853f); }

// Wave front around the home LED (index 0) of an n-LED ring: the phase depends only on the
// distance along the ring, so both sides mirror each other and the pattern reads as rings
// expanding from home rather than a blob running around.
float ring_wave(int i, int n, int64_t t, int64_t period_ms) {
  const float lambda = std::max(1.f, n / 2.f);  // home -> far side is one full cycle
  const float ph = float(t % period_ms) / float(period_ms);
  return 0.5f + 0.5f * std::cos(6.2831853f * (std::min(i, n - i) / lambda - ph));
}

uint8_t to8(float v, float dim) {
  v = std::max(0.f, std::min(1.f, v)) * kMaxScale * dim;
  // Gamma 2.0 so that perceived brightness is roughly linear in v.
  return uint8_t(std::lround(v * v * 255.f));
}

// Palette
const Col kCyan = rgb(0, 190, 255);
const Col kBlue = rgb(55, 15, 255);  // Yandex "alice" violet-blue (0x370fff)
const Col kWhite = rgb(255, 255, 255);
const Col kRed = rgb(255, 0, 0);
const Col kOrange = rgb(255, 90, 0);

const Col kWake = rgb(120, 230, 255);
}  // namespace

struct Leds::Impl {
  Impl(Loop &l, const Model &m) : loop(l), model(m), n(m.ring.count), nlogo(m.logo.count) {}
  Loop &loop;
  const Model &model;
  const int n, nlogo;  // ring / logo LED counts

  // output
  int fb_ring = -1, fb_logo = -1;
  fb_var_screeninfo var_ring{}, var_logo{};
  std::vector<int> sysfs_fds;  // fallback: [ring r,g,b x n][logo r,g,b x nlogo]
  std::vector<uint8_t> last;

  // state
  UiState state = UiState::IDLE;
  int64_t state_t0 = 0;
  bool user_on = false;
  Col user_col = rgb(255, 255, 255);
  float user_bri = 1.f;
  std::string effect;
  float volume = 0;
  int64_t volume_until = 0;
  int64_t swipe_t0 = 0, swipe_until = 0;
  int swipe_dir = 0;  // +1 next, -1 previous
  int64_t hold_t0 = 0, hold_until = 0;
  int64_t command_t0 = 0, command_until = 0;
  uint64_t timer = 0;
  AmbientDimmer dimmer;
  int64_t warn_t[2] = {0, 0};  // last fb0/fb1 write warning
  unsigned warn_suppressed[2] = {0, 0};

  ~Impl() {
    if (timer) loop.cancel_timer(timer);
    clear();  // do not leave the last frame lit after the daemon exits
    if (fb_ring >= 0) close(fb_ring);
    if (fb_logo >= 0) close(fb_logo);
    for (int fd : sysfs_fds)
      if (fd >= 0) close(fd);
  }

  static bool trigger_is(const std::string &led, const std::string &trig) {
    std::string t;
    if (!hwutil::read_file(std::string(kLedDir) + led + "/trigger", t)) return false;
    return t.find("[" + trig + "]") != std::string::npos;
  }

  std::string led_name(const Model::LedStrip &s, const char *color, int i) const {
    return model.led_prefix + ":" + color + ":" + s.sysfs_kind + std::to_string(s.first_index + i);
  }

  // Opens one strip's framebuffer if its trigger is active and the fb has the expected name.
  int open_strip_fb(const Model::LedStrip &s, fb_var_screeninfo &var) {
    if (s.fb_dev.empty()) return -1;  // model without a ledfb (Mini 2): sysfs LEDs only
    if (!trigger_is(led_name(s, "red", 0), s.trigger)) {
      LOGW("leds: trigger %s not active on %s", s.trigger.c_str(), led_name(s, "red", 0).c_str());
      return -1;
    }
    std::string name;
    hwutil::read_file("/sys/class/graphics/" + s.fb_dev.substr(s.fb_dev.rfind('/') + 1) + "/name", name);
    if (hwutil::trim(name) != s.fb_name) {
      LOGW("leds: %s is '%s', expected '%s'", s.fb_dev.c_str(), hwutil::trim(name).c_str(), s.fb_name.c_str());
      return -1;
    }
    int fd = ::open(s.fb_dev.c_str(), O_RDWR | O_CLOEXEC);
    if (fd < 0) {
      LOGW("leds: open %s: %s", s.fb_dev.c_str(), strerror(errno));
      return -1;
    }
    ioctl(fd, FBIOGET_VSCREENINFO, &var);
    return fd;
  }

  bool open_fb() {
    fb_ring = open_strip_fb(model.ring, var_ring);
    if (nlogo) fb_logo = open_strip_fb(model.logo, var_logo);
    if (fb_ring >= 0 && (!nlogo || fb_logo >= 0)) return true;
    if (fb_ring >= 0) close(fb_ring);
    if (fb_logo >= 0) close(fb_logo);
    fb_ring = fb_logo = -1;
    return false;
  }

  bool open_sysfs() {
    static const char *cols[] = {"red", "green", "blue"};
    for (int i = 0; i < n + nlogo; i++)
      for (const char *c : cols) {
        std::string path = kLedDir + (i < n ? led_name(model.ring, c, i) : led_name(model.logo, c, i - n)) +
                           "/brightness";
        int fd = ::open(path.c_str(), O_WRONLY | O_CLOEXEC);
        if (fd < 0) {
          LOGE("leds: cannot open %s", path.c_str());
          return false;
        }
        sysfs_fds.push_back(fd);
      }
    return true;
  }

  // Ring/logo brightness factor from ambient light: 0.3 in the dark .. 1.
  float dim() const { return 0.3f + 0.7f * (dimmer.factor() - 0.02f) / 0.98f; }

  void clear() {
    std::vector<Col> off(size_t(std::max(n, nlogo)));
    last.clear();
    output(off.data(), off.data());
  }

  void warn_write(int which, const char *what) {
    int64_t now = Loop::now_ms();
    if (warn_t[which] && now - warn_t[which] < kWarnEveryMs) {
      warn_suppressed[which]++;
      return;
    }
    LOGW("leds: %s write: %s (%u similar suppressed)", what, strerror(errno), warn_suppressed[which]);
    warn_t[which] = now;
    warn_suppressed[which] = 0;
  }

  // Writes count pixels of px (RGB) to a framebuffer as BGR and latches them.
  // which: 0 = ring, 1 = logo (write warning rate limit).
  void write_fb(int fd, fb_var_screeninfo &var, const uint8_t *px, int count, int which, const char *what) {
    std::vector<uint8_t> bgr(size_t(count) * 3);
    for (int i = 0; i < count; i++) {
      bgr[i * 3] = px[i * 3 + 2];
      bgr[i * 3 + 1] = px[i * 3 + 1];
      bgr[i * 3 + 2] = px[i * 3];
    }
    if (pwrite(fd, bgr.data(), bgr.size(), 0) != ssize_t(bgr.size())) warn_write(which, what);
    ioctl(fd, FBIOPAN_DISPLAY, &var);  // latch
  }

  void output(const Col *ring, const Col *logo) {
    std::vector<uint8_t> px(size_t(n + nlogo) * 3);
    const float d = dim();
    for (int i = 0; i < n + nlogo; i++) {
      const Col &c = i < n ? ring[i] : logo[i - n];
      px[i * 3 + 0] = to8(c.r, d);
      px[i * 3 + 1] = to8(c.g, d);
      px[i * 3 + 2] = to8(c.b, d);
    }
    const bool have_last = !last.empty();
    if (fb_ring >= 0) {
      if (!have_last || memcmp(px.data(), last.data(), size_t(n) * 3) != 0)
        write_fb(fb_ring, var_ring, px.data(), n, 0, "ring fb");
      if (fb_logo >= 0 && (!have_last || memcmp(px.data() + n * 3, last.data() + n * 3, size_t(nlogo) * 3) != 0))
        write_fb(fb_logo, var_logo, px.data() + n * 3, nlogo, 1, "logo fb");
    } else {
      for (size_t k = 0; k < sysfs_fds.size(); k++)
        if (!have_last || px[k] != last[k]) hwutil::write_int_fd(sysfs_fds[k], px[k]);
    }
    last = std::move(px);
  }

  // Renders the current frame; returns true if the content is animated (needs further frames).
  bool render(int64_t now, Col *ring) {
    int64_t t = now - state_t0;
    for (int i = 0; i < n; i++) ring[i] = {};
    bool animated = true;
    switch (state) {
      case UiState::IDLE:
        animated = render_user(now, ring);
        break;
      case UiState::WAKE: {
        // Sweep from ring0 outward in both directions in 250 ms, then hold bright ice-blue.
        float reach = std::min(1.f, float(t) / 250.f) * (n / 2 + 1);
        for (int i = 0; i <= n / 2; i++) {
          float k = std::max(0.f, std::min(1.f, reach - i));
          ring[i] = kWake * k;
          ring[(n - i) % n] = ring[i];
        }
        animated = t < 300;
        break;
      }
      case UiState::LISTENING: {
        // Listening: the whole ring breathes evenly, a calm "microphone is open" glow - no
        // travelling light.
        const float k = 0.34f + 0.42f * wave(t, 2400);
        for (int i = 0; i < n; i++) ring[i] = kCyan * k;
        break;
      }
      case UiState::THINKING: {
        // The request is being processed: a soft wave leaves the home LED and runs out to both
        // sides. Symmetric, with no hard edges and no rotating head.
        for (int i = 0; i < n; i++) ring[i] = kBlue * (0.12f + 0.72f * ring_wave(i, n, t, kThinkWaveMs));
        break;
      }
      case UiState::SPEAKING: {
        // The answer plays: the same wave, quicker and brighter, as if pouring out of the ring.
        for (int i = 0; i < n; i++) ring[i] = kWake * (0.3f + 0.62f * ring_wave(i, n, t, kSpeakWaveMs));
        break;
      }
      case UiState::ERROR: {
        // 3 blinks (200 ms on / 200 ms off), then back to IDLE.
        if (t >= 1200) {
          set_state(UiState::IDLE, now);
          return render(now, ring);
        }
        float k = (t % 400) < 200 ? 0.9f : 0.f;
        for (int i = 0; i < n; i++) ring[i] = kRed * k;
        break;
      }
      case UiState::MUTED:
        // Steady red, clearly visible but below ERROR's 0.9 blink. With the gamma-2.0 curve 0.25
        // rendered at ~10/255 and read as "ring off" on the Mini 2.
        for (int i = 0; i < n; i++) ring[i] = kRed * 0.7f;
        animated = false;
        break;
      case UiState::TIMER_RING: {
        float k = 0.15f + 0.85f * wave(t, 1000);
        for (int i = 0; i < n; i++) ring[i] = kOrange * k;
        break;
      }
    }
    if (now < volume_until) {
      // Volume bar from LED 0. The leading LED brightens continuously instead of switching on
      // (a faint sixth LED looked like the level jumping between whole LEDs), and the bar fades
      // out over its last 250 ms.
      const float pos = volume * n;
      const float fade = std::min(1.f, float(volume_until - now) / 250.f);
      for (int i = 0; i < n; i++) {
        const float k = std::max(0.f, std::min(1.f, (pos - i) * 1.6f));
        ring[i] = kWhite * (0.8f * k * fade);
      }
      animated = true;  // need a frame when the overlay expires
    }
    if (swipe_until && now < swipe_until) {
      // Track change: one comet lap in the direction of the gesture. The head has a soft leading
      // edge and the tail fades to zero (the old cutoff switched LEDs off at 20 % brightness and
      // the head lit each new LED at full brightness, which read as steps on six LEDs). The head
      // starts and ends completely off the ring, so the animation fades in and out instead of
      // popping. Smoothstep easing over the lap keeps the ends soft.
      const float p = float(now - swipe_t0) / float(swipe_until - swipe_t0);
      const float ps = p * p * (3.f - 2.f * p);
      const float tail = std::max(2.f, n * 0.5f);
      const float front = 1.2f;  // soft leading edge, LED units
      const float span = (n - 1) + tail + front;
      const float head = swipe_dir > 0 ? -front + ps * span : (n - 1 + front) - ps * span;
      for (int i = 0; i < n; i++) {
        const float d = swipe_dir > 0 ? head - i : i - head;  // distance behind the head
        float k = d >= 0 ? 1.f - d / tail : 1.f + d / front;
        k = std::max(0.f, std::min(1.f, k));
        k = k * k * (3.f - 2.f * k);
        if (k > 0) ring[i] = kCyan * (0.85f * k);
      }
      animated = true;  // need a frame when the overlay expires
    }
    if (hold_until && now < hold_until) {
      // Action-button hold (play/pause): the whole ring rises and falls once, smoothly, instead of
      // a rotating spinner.
      const float p = float(now - hold_t0) / float(hold_until - hold_t0);
      const float k = std::sin(3.14159265f * p);
      for (int i = 0; i < n; i++) ring[i] = kCyan * (0.85f * k);
      animated = true;  // need a frame when the pulse expires
    }
    if (command_until && now < command_until) {
      // Voice command accepted: the whole ring lights up once and goes out. The command spotter
      // can fire without the wake word ("стоп", "пауза" over the music), so this is the only
      // visible sign that the station heard and acted on the word. Drawn last: it must read on
      // top of whatever the ring currently shows.
      const float p = float(now - command_t0) / float(command_until - command_t0);
      const float k = std::sin(3.14159265f * p);
      for (int i = 0; i < n; i++) ring[i] = kWake * (0.95f * k);
      animated = true;  // need a frame when the pulse expires
    }
    return animated;
  }

  bool render_user(int64_t now, Col *ring) {
    if (!user_on || user_bri <= 0) return false;
    Col base = user_col * user_bri;
    if (effect == "Rainbow") {
      float off = float(now % 6000) / 6000.f;
      for (int i = 0; i < n; i++) ring[i] = hsv(off + float(i) / n, 1.f, user_bri);
      return true;
    }
    if (effect == "Breathe") {
      float k = 0.1f + 0.9f * wave(now, 4000);
      for (int i = 0; i < n; i++) ring[i] = base * k;
      return true;
    }
    for (int i = 0; i < n; i++) ring[i] = base;
    return false;
  }

  void set_state(UiState s, int64_t now) {
    state = s;
    state_t0 = now;
  }

  void frame() {
    int64_t now = Loop::now_ms();
    std::vector<Col> ring(static_cast<size_t>(n));
    bool animated = render(now, ring.data());
    // Logo mirrors the ring's average colour.
    Col avg;
    for (auto &c : ring) avg = {avg.r + c.r / n, avg.g + c.g / n, avg.b + c.b / n};
    std::vector<Col> logo(size_t(nlogo), avg);
    output(ring.data(), logo.data());
    if (animated && !timer) {
      timer = loop.add_timer(kFrameMs, [this] { frame(); }, kFrameMs);
    } else if (!animated && timer) {
      loop.cancel_timer(timer);
      timer = 0;
    }
  }
};

Leds::Leds(Loop &loop, const Model &model) : impl_(new Impl(loop, model)) {}
Leds::~Leds() = default;

bool Leds::open() {
  auto &d = *impl_;
  if (d.open_fb()) {
    LOGI("leds: driving %d ring + %d logo LEDs via framebuffer", d.n, d.nlogo);
  } else if (d.open_sysfs()) {
    LOGI("leds: driving %d ring + %d logo LEDs via sysfs brightness", d.n, d.nlogo);
  } else {
    return false;
  }
  d.state_t0 = Loop::now_ms();
  d.frame();
  return true;
}

void Leds::set_ui_state(UiState s) {
  auto &d = *impl_;
  if (s == d.state) return;
  d.set_state(s, Loop::now_ms());
  d.frame();
}

void Leds::set_user_light(bool on, Rgb color, float brightness, const std::string &effect) {
  auto &d = *impl_;
  d.user_on = on;
  d.user_col = rgb(color.r, color.g, color.b);
  d.user_bri = std::max(0.f, std::min(1.f, brightness));
  d.effect = effect;
  d.frame();
}

void Leds::set_ambient_lux(float lux) {
  auto &d = *impl_;
  if (d.dimmer.update(lux)) d.frame();
}

void Leds::show_volume(float v) {
  auto &d = *impl_;
  d.volume = std::max(0.f, std::min(1.f, v));
  d.volume_until = Loop::now_ms() + kVolumeShowMs;
  d.frame();
}

void Leds::show_swipe(bool next) {
  auto &d = *impl_;
  d.volume_until = 0;  // the swipe's first zone already flashed a volume arc
  d.swipe_dir = next ? 1 : -1;
  d.swipe_t0 = Loop::now_ms();
  d.swipe_until = d.swipe_t0 + kSwipeShowMs;
  d.frame();
}

void Leds::show_hold() {
  auto &d = *impl_;
  d.volume_until = 0;  // the gesture is the action button: no volume bar of its own
  d.hold_t0 = Loop::now_ms();
  d.hold_until = d.hold_t0 + kHoldShowMs;
  d.frame();
}

void Leds::show_command() {
  auto &d = *impl_;
  d.command_t0 = Loop::now_ms();
  d.command_until = d.command_t0 + kCommandShowMs;
  d.frame();
}

}  // namespace cs
