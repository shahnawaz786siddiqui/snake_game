// Slither-style game in Flutter
// Packages needed:  flutter pub add audioplayers shared_preferences
import 'dart:convert';
import 'dart:io' show HttpServer, InternetAddress, InternetAddressType, NetworkInterface, WebSocket, WebSocketTransformer;
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show PointMode;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb, kReleaseMode, defaultTargetPlatform, TargetPlatform, compute;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' as gma;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: GamePage()));
}

// ================================================================ globals
double worldSize = 5000;
int get foodCount => (worldSize * worldSize / 28000).round();
int get powerCount => max(6, (worldSize * worldSize / 2200000).round());
final Random rnd = Random();

// food types: 0 pizza, 1 bun, 2 kheera, 3 onion, 4 cold drink
const foodTypes = 5;
const skinNames = ['Classic', 'Banded', 'Rainbow', 'Zebra', 'Fire', 'Candy', 'Rust', 'Ocean'];

enum Screen { home, play }

enum NetRole { none, host, client }

// ---- difficulty: 0 = Easy, 1 = Medium, 2 = Hard
int difficulty = 1;
const diffNames = ['Easy', 'Medium', 'Hard'];
double get huntShare => const [0.25, 0.7, 0.95][difficulty]; // fraction of bots that hunt
double get chaseRange => const [600.0, 900.0, 1900.0][difficulty]; // how far bots spot a player
double get chaseSpeed => const [1.0, 1.08, 1.06][difficulty]; // bot speed while chasing a player
double get boostNear => const [250.0, 480.0, 420.0][difficulty]; // distance where bots boost
bool get farBoost => difficulty == 2; // hard bots also boost from far away
double get botGrowth => const [0.8, 1.25, 3.2][difficulty]; // how fast bots grow when they eat
double get botBoostCost => const [5.0, 5.0, 1.5][difficulty]; // length a bot loses per second of boost
int get maxHunters => const [1, 2, 5][difficulty]; // how many bots may attack you at the same time
double get startGrace => const [12.0, 12.0, 10.0][difficulty]; // seconds at the start with no attack
double newAggr() => rnd.nextDouble() < huntShare ? 0.6 + rnd.nextDouble() * 0.4 : rnd.nextDouble() * 0.45;

const int kPort = 4040;
const int kMaxRevives = 2; // revives (rewarded ads) allowed per round

// movement speeds (same for the player and for the bots)
const double kBaseSpeed = 155.0;
const double kBoostSpeed = 280.0;

class NetConn {
  final WebSocket ws;
  final Snake snake;
  NetConn(this.ws, this.snake);
}

class MiniDot {
  final Offset p;
  final Color c;
  final bool me;
  MiniDot(this.p, this.c, this.me);
}

double wrapAngle(double d) {
  while (d > pi) d -= 2 * pi;
  while (d < -pi) d += 2 * pi;
  return d;
}

Color skinColor(int skin, Color base, int i, int n) {
  switch (skin) {
    case 1:
      return (i ~/ 3).isEven ? base : Colors.white;
    case 2:
      return HSVColor.fromAHSV(1, (i * 14.0) % 360, 0.75, 1).toColor();
    case 3:
      return (i ~/ 3).isEven ? Colors.white : const Color(0xFF1E1E1E);
    case 4:
      return Color.lerp(const Color(0xFFFFEB3B), const Color(0xFFD50000), (i / max(n - 1, 1)).clamp(0.0, 1.0))!;
    case 5:
      return (i ~/ 2).isEven ? const Color(0xFFFF6FA5) : Colors.white;
    case 6: // centipede
      if (i == 0) return const Color(0xFF8B2E12);
      return i.isEven ? const Color(0xFFB5541C) : const Color(0xFFE08A2E);
    case 7: // ocean
      return Color.lerp(const Color(0xFF00E5FF), const Color(0xFF283593), 0.5 + 0.5 * sin(i * 0.4))!;
    default:
      return i.isEven ? base : Color.lerp(Colors.black, base, 0.82)!;
  }
}

// ================================================================ sound (generated in code, no asset files)
class Sfx {
  static bool enabled = true;
  static final AudioPlayer _a = AudioPlayer(), _b = AudioPlayer(), _c = AudioPlayer(), _d = AudioPlayer();
  static final Uint8List _eat = _tone(800, 1100, 0.06, 0.35);
  static final Uint8List _die = _tone(420, 70, 0.6, 0.5);
  static final Uint8List _kill = _tone(500, 1300, 0.18, 0.45);
  static final Uint8List _power = _tone(500, 1500, 0.25, 0.45);
  static int _lastEat = 0;

  static Uint8List _tone(double f0, double f1, double dur, double vol) {
    const sr = 22050;
    final n = (sr * dur).toInt();
    final data = ByteData(44 + n * 2);
    void s(int o, String t) {
      for (int i = 0; i < t.length; i++) {
        data.setUint8(o + i, t.codeUnitAt(i));
      }
    }

    s(0, 'RIFF');
    data.setUint32(4, 36 + n * 2, Endian.little);
    s(8, 'WAVE');
    s(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, sr, Endian.little);
    data.setUint32(28, sr * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    s(36, 'data');
    data.setUint32(40, n * 2, Endian.little);
    double ph = 0;
    for (int i = 0; i < n; i++) {
      final t = i / n;
      ph += 2 * pi * (f0 + (f1 - f0) * t) / sr;
      data.setInt16(44 + i * 2, (sin(ph) * (1 - t) * vol * 32767).toInt(), Endian.little);
    }
    return data.buffer.asUint8List();
  }

  static void _play(AudioPlayer p, Uint8List b) {
    if (!enabled) return;
    try {
      p.play(BytesSource(b), volume: 0.7).catchError((_) {});
    } catch (_) {}
  }

  static void eat() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastEat < 260) return; // LAG FIX: fewer audio calls while eating a lot
    _lastEat = now;
    _play(_a, _eat);
  }

  static final FlutterTts _tts = FlutterTts();
  static bool _ttsReady = false;

  // plays an "Oh no!" voice after you die
  static Future<void> _voice() async {
    if (!enabled) return;
    try {
      if (!_ttsReady) {
        _ttsReady = true;
        await _tts.setLanguage('en-US');
        await _tts.setVolume(1.0);
        await _tts.setPitch(1.2);
        await _tts.setSpeechRate(0.5);
      }
      await _tts.speak('Oh no!');
    } catch (_) {}
  }

  static void die() {
    _play(_b, _die);
    _voice();
  }
  static void kill() => _play(_c, _kill);
  static void power() => _play(_d, _power);
}


// ================================================================ background music (composed in code: 100% original, no copyright)
class Music {
  static bool enabled = true;
  static final AudioPlayer _p = AudioPlayer();
  static final Map<int, Uint8List> _cache = {};
  static int want = 0; // 1 = home music, 2 = game music
  static int _cur = 0;
  static bool _busy = false, _ctxSet = false;

  static Future<void> play(int kind) async {
    want = kind;
    await sync();
  }

  // makes the player match what is wanted (home / game / off). Safe to call any time.
  static Future<void> sync() async {
    if (_busy) return;
    _busy = true;
    try {
      if (!_ctxSet) {
        _ctxSet = true;
        // music must not be cut by the sound effects (no audio-focus fight between the players)
        try {
          await AudioPlayer.global.setAudioContext(AudioContext(
            android: AudioContextAndroid(audioFocus: AndroidAudioFocus.none),
            iOS: AudioContextIOS(category: AVAudioSessionCategory.ambient),
          ));
        } catch (_) {}
      }
      for (int guard = 0; guard < 6; guard++) {
        final target = enabled ? want : 0;
        if (target == _cur) break;
        if (target == 0) {
          await _p.stop();
          _cur = 0;
          continue;
        }
        final b = _cache[target];
        if (b == null) {
          final built = await compute<int, Uint8List>(_buildTrack, target); // built in the background, the game does not stutter
          _cache[target] = built;
          continue; // check again: the wanted track may have changed meanwhile
        }
        await _p.setReleaseMode(ReleaseMode.loop);
        await _p.setVolume(0.30);
        await _p.play(BytesSource(b));
        _cur = target;
      }
    } catch (_) {
    } finally {
      _busy = false;
    }
  }

  static void pause() {
    if (_cur == 0) return;
    try {
      _p.pause();
    } catch (_) {}
  }

  static void resume() {
    if (_cur == 0 || !enabled) return;
    try {
      _p.resume();
    } catch (_) {}
  }
}

/// Builds one looping music track (kind 1 = calm home theme, kind 2 = fast game theme) as a WAV file.
/// The loop is seamless: note tails wrap around to the start.
Uint8List _buildTrack(int kind) {
  const sr = 22050;
  final game = kind == 2;
  final beat = 60.0 / (game ? 128.0 : 92.0);
  const bars = 8;
  final n = (beat * 4 * bars * sr).round();
  final buf = Float64List(n);
  int seed = 12345;
  double noise() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x3fffffff - 1.0;
  }

  // one synth note. wave: 0 sine, 1 triangle, 2 soft square. dec > 0 = plucked, dec == 0 = soft pad
  void tone(double t0, double dur, double f, double amp, int wave, double dec) {
    final i0 = (t0 * sr).round();
    final len = (dur * sr).round();
    final dp = 2 * pi * f / sr;
    double ph = 0;
    for (int i = 0; i < len; i++) {
      final t = i / sr;
      double env;
      if (dec > 0) {
        env = exp(-t * dec);
      } else {
        env = min(1.0, min(t / 0.45, (dur - t) / 0.45));
      }
      env *= min(1.0, min(t / 0.005, (dur - t) / 0.01));
      if (env <= 0) {
        ph += dp;
        continue;
      }
      double v;
      if (wave == 0) {
        v = sin(ph);
      } else if (wave == 1) {
        v = 2 / pi * asin(sin(ph));
      } else {
        v = (sin(ph) + sin(ph * 3) / 3 + sin(ph * 5) / 5) * 0.7;
      }
      ph += dp;
      buf[(i0 + i) % n] += v * env * amp;
    }
  }

  void kick(double t0) {
    final i0 = (t0 * sr).round();
    final len = (0.22 * sr).round();
    double ph = 0;
    for (int i = 0; i < len; i++) {
      final t = i / sr;
      ph += 2 * pi * (45 + 90 * exp(-t * 28)) / sr;
      buf[(i0 + i) % n] += sin(ph) * exp(-t * 13) * 0.55;
    }
  }

  void hit(double t0, double dur, double amp, double dec) {
    final i0 = (t0 * sr).round();
    final len = (dur * sr).round();
    double prev = 0;
    for (int i = 0; i < len; i++) {
      final t = i / sr;
      final x = noise();
      buf[(i0 + i) % n] += (x - prev) * 0.5 * exp(-t * dec) * amp;
      prev = x;
    }
  }

  // A minor - F - C - G
  const chords = [
    [220.0, 261.63, 329.63],
    [174.61, 220.0, 261.63],
    [261.63, 329.63, 392.0],
    [196.0, 246.94, 293.66],
  ];
  const roots = [110.0, 87.31, 130.81, 98.0];
  const mel = <List<double>>[
    [659.25, 0, 587.33, 0, 523.25, 0, 587.33, 0],
    [523.25, 0, 440.0, 0, 523.25, 587.33, 523.25, 0],
    [659.25, 0, 783.99, 0, 659.25, 0, 587.33, 523.25],
    [587.33, 0, 659.25, 0, 587.33, 0, 493.88, 0],
  ];
  const arpHome = [0, 1, 2, 1, 0, 1, 2, 1];
  const arpGame = [0, 1, 2, 1, 2, 1, 0, 1, 2, 1, 2, 1, 0, 2, 1, 2];

  for (int b = 0; b < bars; b++) {
    final c = b % 4;
    final t0 = b * 4 * beat;
    final ch = chords[c];
    final root = roots[c];
    final second = b >= 4; // second half of the loop adds a melody

    for (final f in ch) {
      tone(t0, beat * 4, f, game ? 0.055 : 0.11, 0, 0); // pad
    }

    if (!game) {
      tone(t0, beat * 2, root, 0.30, 0, 1.3);
      tone(t0 + beat * 2, beat * 2, root, 0.22, 0, 1.3);
      for (int k = 0; k < 8; k++) {
        tone(t0 + k * beat / 2, beat * 0.9, ch[arpHome[k]] * 2, 0.15, 1, 4.5);
      }
      if (second) {
        for (int k = 0; k < 8; k++) {
          final f = mel[c][k];
          if (f > 0) tone(t0 + k * beat / 2, beat * 0.9, f, 0.14, 0, 2.5);
        }
      }
    } else {
      for (int k = 0; k < 4; k++) {
        kick(t0 + k * beat);
      }
      hit(t0 + beat, 0.16, 0.22, 20);
      hit(t0 + 3 * beat, 0.16, 0.22, 20);
      for (int k = 0; k < 8; k++) {
        final ts = t0 + k * beat / 2;
        if (k.isOdd) hit(ts, 0.05, 0.10, 70);
        final oct = (k == 3 || k == 7) ? 2.0 : 1.0;
        tone(ts, beat * 0.45, root * 2 * oct, 0.17, 2, 5);
      }
      for (int k = 0; k < 16; k++) {
        tone(t0 + k * beat / 4, beat * 0.22, ch[arpGame[k]] * 2, 0.07, 2, 10);
      }
      if (second) {
        for (int k = 0; k < 8; k++) {
          final f = mel[c][k];
          if (f > 0) tone(t0 + k * beat / 2, beat * 0.9, f, 0.10, 1, 3);
        }
      }
    }
  }

  double peak = 0;
  for (final v in buf) {
    final a = v.abs();
    if (a > peak) peak = a;
  }
  final gain = peak > 0 ? 0.85 / peak : 1.0;
  final data = ByteData(44 + n * 2);
  void w(int o, String t) {
    for (int i = 0; i < t.length; i++) {
      data.setUint8(o + i, t.codeUnitAt(i));
    }
  }

  w(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  w(8, 'WAVE');
  w(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sr, Endian.little);
  data.setUint32(28, sr * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  w(36, 'data');
  data.setUint32(40, n * 2, Endian.little);
  for (int i = 0; i < n; i++) {
    data.setInt16(44 + i * 2, (buf[i] * gain * 32767).round().clamp(-32767, 32767), Endian.little);
  }
  return data.buffer.asUint8List();
}

// ================================================================ models
class Food {
  Offset pos;
  double r;
  int type;
  bool eaten = false;
  Food(this.pos, this.r, this.type);
}

class PowerUp {
  Offset pos;
  int type; // 0 speed, 1 magnet, 2 shield
  PowerUp(this.pos, this.type);
}

class Snake {
  final bool isPlayer;
  String name;
  Color color;
  int skin;
  final List<Offset> body = [];
  double angle = 0, target = 0, len = 12;
  bool boosting = false, alive = true;
  double dropTimer = 0, aiTimer = 0, respawn = 0;
  double speedT = 0, magnetT = 0, shieldT = 0;
  int kills = 0;
  int id = 0;
  bool remote = false, respawnReq = false, netBoost = false;
  double netTarget = 0;
  List<Offset>? net;
  double aggr = 0.6; // > 0.5 means this bot hunts other snakes
  double speedMul = 1.0;
  double turnMul = 1.0;
  double coolT = 0, huntT = 0; // attack cooldown / how long it has been hunting
  bool avoiding = false; // LAG FIX: bot was steering away from a body on its last scan

  // LAG FIX: bounding box of the whole body (used to skip far snakes quickly in collisions and drawing)
  double minX = -1e9, minY = -1e9, maxX = 1e9, maxY = 1e9;

  Snake({required this.isPlayer, required this.name, required this.color, required Offset start, this.skin = 0}) {
    reset(start);
  }

  Offset get head => body.first;
  double get radius => 10 + min(len, 700) / 20;
  double get spacing => radius * 0.55;
  int get score => ((len - 12) * 10).floor();

  void updateBounds() {
    if (body.isEmpty) return;
    double x0 = body[0].dx, x1 = x0, y0 = body[0].dy, y1 = y0;
    for (int i = 1; i < body.length; i++) {
      final p = body[i];
      final x = p.dx, y = p.dy;
      if (x < x0) {
        x0 = x;
      } else if (x > x1) {
        x1 = x;
      }
      if (y < y0) {
        y0 = y;
      } else if (y > y1) {
        y1 = y;
      }
    }
    minX = x0;
    maxX = x1;
    minY = y0;
    maxY = y1;
  }

  // make the snake longer right away (used for the big starting snakes)
  void grow(double l) {
    len = l;
    final dir = Offset(cos(angle), sin(angle));
    while (body.length < len.floor()) {
      body.add(body.last - dir * spacing);
    }
    updateBounds();
  }

  void reset(Offset start) {
    alive = true;
    len = 12;
    kills = 0;
    boosting = false;
    speedT = magnetT = shieldT = 0;
    coolT = 0;
    huntT = 0;
    avoiding = false;
    angle = rnd.nextDouble() * 2 * pi;
    target = angle;
    body.clear();
    final dir = Offset(cos(angle), sin(angle));
    for (int i = 0; i < 12; i++) {
      body.add(start - dir * (spacing * i));
    }
    updateBounds();
  }

  void move(double dt) {
    final diff = wrapAngle(target - angle);
    final maxTurn = 4.2 * dt * turnMul;
    angle += diff.clamp(-maxTurn, maxTurn);
    final sp = (boosting ? kBoostSpeed : kBaseSpeed) * (speedT > 0 ? 1.3 : 1.0) * speedMul;
    body[0] = body[0] + Offset(cos(angle), sin(angle)) * sp * dt;
    final sc = spacing;
    final sc2 = sc * sc;
    // LAG FIX: no temporary Offsets / sqrt unless the segment really has to move
    for (int i = 1; i < body.length; i++) {
      final a = body[i - 1], b = body[i];
      final dx = a.dx - b.dx, dy = a.dy - b.dy;
      final d2 = dx * dx + dy * dy;
      if (d2 > sc2) {
        final k = sc / sqrt(d2);
        body[i] = Offset(a.dx - dx * k, a.dy - dy * k);
      }
    }
    while (body.length < len.floor()) body.add(body.last);
    while (body.length > max(10, len.floor())) body.removeLast();
  }
}

// ================================================================ page
class GamePage extends StatefulWidget {
  const GamePage({super.key});
  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker ticker;
  Duration last = Duration.zero;
  final FocusNode gameFocus = FocusNode();
  final TextEditingController nameCtrl = TextEditingController();
  final ValueNotifier<double> homeClock = ValueNotifier(0);
  final TextEditingController ipCtrl = TextEditingController();

  // multiplayer state
  NetRole role = NetRole.none;
  HttpServer? server;
  WebSocket? clientWs;
  final Map<int, NetConn> conns = {};
  final Map<int, Snake> netSnakes = {};
  List<List<dynamic>> netBoard = [];
  List<MiniDot> netDots = [];
  int nextId = 1, myNetId = -1;
  double _sendAcc = 0, clientTarget = 0;
  final Set<int> attackers = {}; // bots that are allowed to attack right now
  final Map<int, int> attackRank = {}; // HARD: role of every attacking bot (0 interceptor, 1/2 flankers, 3/4 cutters, 5+ chasers)
  double _slotAcc = 0, graceT = 10;
  int revivesLeft = kMaxRevives;
  List<List<dynamic>> _boardCache = [];
  double _boardAcc = 0;
  double arrowAlpha = 0; // fades the direction arrow in / out
  double _lastHomeT = 0, _lastMoreT = 0;
  final ScrollController homeScroll = ScrollController();
  final ValueNotifier<bool> moreBelow = ValueNotifier(false); // true when Skins / Map / Settings are hidden below
  bool firstSnap = true, netBusy = false;
  String hostIp = '';
  String? netMsg;
  SharedPreferences? prefs;

  // LAG FIX helpers
  int _frame = 0; // frame counter (bots scan for obstacles every 2nd frame)
  final Map<int, List<Food>> _foodGrid = {}; // food grid is reused every frame (no new lists)

  Screen screen = Screen.home;
  final List<Food> foods = [];
  final List<PowerUp> powers = [];
  final List<Snake> snakes = [];
  late Snake player;
  int botCount = 25;
  Size size = Size.zero;
  Offset pointer = Offset.zero;
  bool hasPointer = false, boostHeld = false;

  // touch-drag steering (joystick OFF)
  Offset? touchAnchor; // the "centre": where the finger started (it follows the finger)
  Offset touchPos = Offset.zero;
  bool touchActive = false, hasTouchSteer = false;
  double touchAngle = 0;
  Offset cam = const Offset(2500, 2500);

  // joystick
  Offset joy = Offset.zero;
  bool joyActive = false;

  // settings (saved)
  static const palette = [
    Colors.redAccent, Colors.orangeAccent, Colors.yellow, Colors.lightGreenAccent, Colors.cyanAccent,
    Colors.lightBlueAccent, Colors.purpleAccent, Colors.pinkAccent, Colors.tealAccent, Colors.amber
  ];
  static const colorChoices = [Colors.greenAccent, ...palette];
  int colorIdx = 0, skin = 0, mapChoice = 1;
  bool showNames = true, showBoard = true, sound = true, showArrow = true, joystick = true; // joystick is ON by default
  bool music = true; // background music on / off
  int lastScore = 0, lastKills = 0, bestScore = 0, bestKills = 0;

  Color get playerColor => colorChoices[colorIdx];

  static const mapSizes = [3500.0, 5000.0, 6500.0];
  static const mapNames = ['Small', 'Big', 'Huge'];
  static const botNames = [
    'Viper', 'Noodle', 'Mamba', 'Cobra', 'Slinky', 'Python', 'Rattler', 'Zippy', 'Basilisk', 'Naga',
    'Sidewinder', 'Anaconda', 'Ziggy', 'Wiggles', 'Boa', 'Sneaky', 'Kaa', 'Medusa', 'Jormungandr', 'Sir Hiss'
  ];

  Offset randomPos([double margin = 300]) =>
      Offset(margin + rnd.nextDouble() * (worldSize - 2 * margin), margin + rnd.nextDouble() * (worldSize - 2 * margin));

  Food newFood() => Food(randomPos(30), 8 + rnd.nextDouble() * 5, rnd.nextInt(foodTypes));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    player = Snake(isPlayer: true, name: 'You', color: playerColor, start: const Offset(2500, 2500));
    ticker = createTicker(_tick)..start();
    _load();
    // start the ads SDK only AFTER the first screen is visible (keeps the start fast on slow phones)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 2), AdsManager.init);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _leaveNet();
    homeScroll.dispose();
    moreBelow.dispose();
    ipCtrl.dispose();
    ticker.dispose();
    gameFocus.dispose();
    nameCtrl.dispose();
    super.dispose();
  }

  // music stops when the app goes to the background and continues when you come back
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Music.resume();
    } else {
      Music.pause();
    }
  }

  // ---------------------------------------------------------------- save / load
  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      prefs = p;
      setState(() {
        bestScore = p.getInt('bestScore') ?? 0;
        bestKills = p.getInt('bestKills') ?? 0;
        colorIdx = (p.getInt('colorIdx') ?? 0).clamp(0, colorChoices.length - 1);
        skin = (p.getInt('skin') ?? 0).clamp(0, skinNames.length - 1);
        mapChoice = (p.getInt('mapChoice') ?? 1).clamp(0, mapSizes.length - 1);
        showNames = p.getBool('showNames') ?? true;
        showBoard = p.getBool('showBoard') ?? true;
        sound = p.getBool('sound') ?? true;
        joystick = p.getBool('joystickOn') ?? true;
        showArrow = p.getBool('showArrow') ?? true;
        nameCtrl.text = p.getString('name') ?? '';
        ipCtrl.text = p.getString('lastIp') ?? '';
        difficulty = (p.getInt('difficulty') ?? 1).clamp(0, 2);
        Sfx.enabled = sound;
        music = p.getBool('music') ?? true;
        Music.enabled = music;
      });
      Music.sync();
    } catch (_) {}
  }

  void _save() {
    final p = prefs;
    if (p == null) return;
    try {
      p.setInt('bestScore', bestScore);
      p.setInt('bestKills', bestKills);
      p.setInt('colorIdx', colorIdx);
      p.setInt('skin', skin);
      p.setInt('mapChoice', mapChoice);
      p.setBool('showNames', showNames);
      p.setBool('showBoard', showBoard);
      p.setBool('sound', sound);
      p.setBool('music', music);
      p.setBool('joystickOn', joystick);
      p.setBool('showArrow', showArrow);
      p.setString('name', nameCtrl.text.trim());
      p.setString('lastIp', ipCtrl.text.trim());
      p.setInt('difficulty', difficulty);
    } catch (_) {}
  }

  // ---------------------------------------------------------------- game flow
  void startGame(int bots, {bool hosting = false}) {
    if (!hosting) _leaveNet();
    botCount = bots;
    if (difficulty == 2) bots += 5; // hard: extra bots
    graceT = startGrace; // no attacks for the first seconds
    revivesLeft = kMaxRevives;
    attackers.clear();
    worldSize = mapSizes[mapChoice];
    final nick = nameCtrl.text.trim();
    snakes.clear();
    player = Snake(
      isPlayer: true,
      name: nick.isEmpty ? 'You' : nick,
      color: playerColor,
      skin: skin,
      start: randomPos(worldSize * 0.2),
    );
    snakes.add(player);
    for (int i = 0; i < bots; i++) {
      final base = botNames[i % botNames.length];
      final name = i >= botNames.length ? '$base${i ~/ botNames.length + 1}' : base;
      snakes.add(Snake(
          isPlayer: false,
          name: name,
          color: palette[rnd.nextInt(palette.length)],
          skin: rnd.nextInt(skinNames.length),
          start: randomPos()));
    }
    // every bot gets a random aggression level; most of them hunt
    for (int i = 1; i < snakes.length; i++) {
      snakes[i].aggr = newAggr();
    }
    if (difficulty == 2) {
      for (int i = 1; i < snakes.length; i++) {
        snakes[i].grow(40 + rnd.nextDouble() * 70); // hard: every bot starts long
      }
    }
    // a few BIG snakes at the start only
    const bigNames = ['Titan', 'Leviathan', 'Anaconda King', 'Basilisk', 'Hydra', 'Colossus'];
    const bigSkins = [4, 3, 2, 1, 5, 7];
    final bigCount = min(bots >= 25 ? const [2, 4, 6][difficulty] : const [1, 2, 3][difficulty], bots);
    for (int i = 0; i < bigCount; i++) {
      final big = snakes[1 + i];
      Offset p = randomPos();
      for (int tries = 0; tries < 40 && (p - player.head).distance < 1200; tries++) {
        p = randomPos();
      }
      big.reset(p);
      big.name = bigNames[i];
      big.skin = bigSkins[i];
      big.aggr = 1.0;
      big.grow(150.0 + rnd.nextDouble() * 80);
      big.shieldT = 15; // protected for the first 15 seconds
    }
    for (int i = 0; i < snakes.length; i++) {
      snakes[i].id = i;
    }
    nextId = snakes.length;
    role = hosting ? NetRole.host : NetRole.none;
    foods.clear();
    while (foods.length < foodCount) {
      foods.add(newFood());
    }
    powers.clear();
    while (powers.length < powerCount) {
      powers.add(PowerUp(randomPos(100), rnd.nextInt(3)));
    }
    cam = player.head;
    hasPointer = false;
    hasTouchSteer = false;
    touchActive = false;
    touchAnchor = null;
    boostHeld = false;
    joyActive = false;
    joy = Offset.zero;
    _save();
    setState(() => screen = Screen.play);
    gameFocus.requestFocus();
  }

  void _tick(Duration t) {
    try {
      final dt = ((t - last).inMicroseconds / 1e6).clamp(0.0, 0.05);
      last = t;
      if (screen == Screen.play) {
        final arrowOn = touchActive || (hasPointer && !hasTouchSteer && !joystick);
        arrowAlpha += ((arrowOn ? 1.0 : 0.0) - arrowAlpha) * min(1.0, dt * 14);
        if (role == NetRole.client) {
          _clientUpdate(dt);
        } else {
          _update(dt);
          if (role == NetRole.host) _hostBroadcast(dt);
        }
        if (mounted) setState(() {});
      } else {
        final sec = t.inMicroseconds / 1e6;
        if (sec - _lastHomeT >= 0.033) {
          _lastHomeT = sec;
          homeClock.value = sec;
        }
        if (sec - _lastMoreT >= 0.15) {
          _lastMoreT = sec;
          _updateMore();
        }
      }
    } catch (e, st) {
      debugPrint('Game tick stopped a frame: $e\n$st');
    }
  }

  void _updateMore() {
    if (!homeScroll.hasClients) return;
    final p = homeScroll.position;
    if (!p.hasContentDimensions) return;
    final more = p.maxScrollExtent - p.pixels > 24;
    if (more != moreBelow.value) moreBelow.value = more;
  }

  // bouncing arrow that tells the player: Skins / Map / Settings are further down
  Widget _moreBelowHint() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 10 + MediaQuery.of(context).padding.bottom,
      child: ValueListenableBuilder<bool>(
        valueListenable: moreBelow,
        builder: (context, more, _) => IgnorePointer(
          ignoring: !more,
          child: AnimatedOpacity(
            opacity: more ? 1 : 0,
            duration: const Duration(milliseconds: 250),
            child: Center(
              child: GestureDetector(
                onTap: () {
                  if (homeScroll.hasClients) {
                    homeScroll.animateTo(homeScroll.position.maxScrollExtent,
                        duration: const Duration(milliseconds: 450), curve: Curves.easeOut);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
                  decoration: BoxDecoration(
                    color: const Color(0xE6181236),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: kCyan.withOpacity(0.7), width: 1.5),
                    boxShadow: [BoxShadow(color: kCyan.withOpacity(0.35), blurRadius: 16)],
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Text('Skins  •  Map  •  Settings',
                        style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1)),
                    const SizedBox(width: 6),
                    ValueListenableBuilder<double>(
                      valueListenable: homeClock,
                      builder: (_, t, __) => Transform.translate(
                        offset: Offset(0, sin(t * 6) * 4),
                        child: const Icon(Icons.keyboard_double_arrow_down, color: kCyan, size: 22),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _recordPlayer() {
    lastScore = player.score;
    lastKills = player.kills;
    bestScore = max(bestScore, player.score);
    bestKills = max(bestKills, player.kills);
    _save();
  }

  void _kill(Snake s) {
    s.alive = false;
    // LAG FIX: a giant snake (1200+ long) drops at most ~600 foods instead of thousands
    final dropStep = max(2, (s.body.length / 600).ceil());
    for (int i = 0; i < s.body.length; i += dropStep) {
      final p = s.body[i] + Offset(rnd.nextDouble() * 10 - 5, rnd.nextDouble() * 10 - 5);
      foods.add(Food(p, 10 + rnd.nextDouble() * 3, rnd.nextInt(foodTypes)));
    }
    if (s.isPlayer) {
      _recordPlayer();
      Sfx.die();
      AdsManager.onGameOver();
    } else {
      s.respawn = 3;
    }
  }

  void _ai(Snake s, double dt) {
    s.aiTimer -= dt;
    if (s.coolT > 0) s.coolT -= dt;
    final h = s.head;
    s.boosting = false;

    // 1) stay inside the map
    final edge = 200 + s.radius * 3;
    if (h.dx < edge || h.dx > worldSize - edge || h.dy < edge || h.dy > worldSize - edge) {
      s.target = atan2(worldSize / 2 - h.dy, worldSize / 2 - h.dx);
      return;
    }

    // 2) hunters pick a prey: nearest snake (real players are preferred)
    Snake? prey;
    s.speedMul = 1.0;
    s.turnMul = difficulty == 2 ? 1.25 : 1.0;
    if (s.aggr > 0.5) {
      double best = 1e9;
      for (final o in snakes) {
        if (o == s || !o.alive) continue;
        final human = o.isPlayer || o.remote;
        if (human && (graceT > 0 || !attackers.contains(s.id))) continue; // only a few bots attack at a time
        if (!human && difficulty == 2 && s.id % 4 != 0) continue; // hard: only some bots hunt other bots
        if (!human && o.len > s.len * 1.8 + 20) continue; // bots avoid much bigger bots
        if (!human && o.len < s.len * 0.4) continue; // big bots do not chase tiny snakes (too risky)
        if (!human && s.len < 25) continue; // tiny bots first grow by eating
        final d = (o.head - h).distance;
        // real players are chased from very far away
        final maxRange = human ? (s.len > 100 ? chaseRange * 1.3 : chaseRange) : 700.0;
        if (d > maxRange) continue;
        if (s.len < 25 && d > 500) continue; // tiny bots only chase a player who is close
        final score = human ? d * (difficulty == 2 ? 0.35 : 0.5) : d;
        if (score < best) {
          best = score;
          prey = o;
        }
      }
    }

    // 3) avoid crashing into bodies (the prey's head area is ignored while attacking)
    // LAG FIX: each bot scans only every 2nd frame (bots are staggered by id). On the other frame
    // it keeps its last avoid direction, so the steering looks exactly the same.
    if (((_frame + s.id) & 1) == 1) {
      if (s.avoiding) {
        if (difficulty == 2) s.turnMul = 2.0; // hard: keep turning sharply while dodging
        return;
      }
    } else {
      s.avoiding = false;
      if (difficulty == 2) {
        // HARD: the smart dodge (looks at the WHOLE body of every snake, picks the side with free space)
        if (_hardAvoid(s, prey)) {
          s.avoiding = true;
          return;
        }
      } else {
        for (final o in snakes) {
          if (o == s || !o.alive) continue;
          final hd = o.head - h;
          if (hd.dx * hd.dx + hd.dy * hd.dy > 490000) continue; // 700 * 700
          final margin = (o == prey && difficulty == 2) ? 22.0 : 70 + min(s.len, 300.0) * 0.25;
          final lim = s.radius + o.radius + margin;
          final lim2 = lim * lim;
          for (int i = (o == prey ? 8 : 0); i < o.body.length; i += 3) {
            final p = o.body[i];
            final d = p - h;
            if (d.dx * d.dx + d.dy * d.dy < lim2) {
              final toP = atan2(d.dy, d.dx);
              if (wrapAngle(toP - s.angle).abs() < 1.6) {
                s.target = toP + (wrapAngle(toP - s.angle) >= 0 ? -1.3 : 1.3);
                s.avoiding = true;
                return;
              }
            }
          }
        }
      }
    }

    // 4) ATTACK: aim in front of the prey's head so it runs into our body
    if (prey != null) {
      final ph = prey.head;
      final dist = (ph - h).distance;
      s.huntT += dt;
      if ((prey.isPlayer || prey.remote) && (dist < 170 || s.huntT > (difficulty == 2 ? 18 : 14))) {
        // attack finished: back off for a while so the player can breathe
        final cd = difficulty == 2 ? 2.2 : 6.0; // hard: very short break between attacks
        s.coolT = cd + rnd.nextDouble() * cd * 0.6;
        s.huntT = 0;
      }
      final pdir = Offset(cos(prey.angle), sin(prey.angle));
      final isHuman = prey.isPlayer || prey.remote;
      final hardHunt = difficulty == 2 && isHuman;
      final lead = difficulty == 0
          ? 0.0
          : (hardHunt
          ? (dist / kBoostSpeed * ((prey.boosting ? kBoostSpeed : kBaseSpeed) * (prey.speedT > 0 ? 1.3 : 1.0)) * 1.15).clamp(100.0, 700.0)
          : (dist * 0.5).clamp(60.0, 260.0)); // easy bots just chase the head
      var aim = ph + pdir * lead;
      var hardBoost = false;
      if (hardHunt) {
        // HARD: the attackers work as a TEAM, every one has a different job (rank 0..3)
        final rank = attackRank[s.id] ?? 0;
        final perp = Offset(-pdir.dy, pdir.dx);
        final rel = h - ph;
        final behind = pdir.dx * rel.dx + pdir.dy * rel.dy < 0;
        final side = (pdir.dx * rel.dy - pdir.dy * rel.dx) >= 0 ? 1.0 : -1.0;
        // where will the player be when we arrive? (uses his speed AND the way he is steering)
        final preySp = (prey.boosting ? kBoostSpeed : kBaseSpeed) * (prey.speedT > 0 ? 1.3 : 1.0);
        final tArr = (dist / kBoostSpeed).clamp(0.2, 2.5).toDouble();
        final turn = wrapAngle(prey.target - prey.angle).clamp(-4.2 * tArr, 4.2 * tArr).toDouble();
        final midA = prey.angle + turn * 0.5;
        var pred = ph + Offset(cos(midA), sin(midA)) * (preySp * tArr);
        pred = Offset(pred.dx.clamp(250.0, worldSize - 250), pred.dy.clamp(250.0, worldSize - 250));
        if (rank == 0) {
          // INTERCEPTOR: get in front of his head, then cross his path (our body becomes a wall)
          if (behind && dist > 160) {
            aim = pred + perp * side * (prey.radius * 2.6 + 40);
            hardBoost = dist < 700;
          } else if (!behind && dist < 700) {
            aim = pred - perp * side * 260;
            hardBoost = true;
          } else {
            aim = pred;
            hardBoost = dist < 450;
          }
        } else if (rank == 1 || rank == 2) {
          // FLANKERS: one comes from his left, one from his right, then both swing across in front (pincer)
          final sg = rank == 1 ? 1.0 : -1.0;
          if (dist > 320) {
            aim = pred + perp * sg * 240;
            hardBoost = dist < 800;
          } else {
            aim = pred + pdir * 50 - perp * sg * 260;
            hardBoost = true;
          }
        } else if (rank == 3) {
          // CUTTER: runs far ahead and lays its body across his path, so he cannot run straight
          var cut = ph + pdir * (preySp * 1.8 + 300);
          cut = Offset(cut.dx.clamp(250.0, worldSize - 250), cut.dy.clamp(250.0, worldSize - 250));
          final dc = (cut - h).distance;
          if (dc > 260) {
            aim = cut;
            hardBoost = dc < 900 && dist > 250;
          } else {
            aim = cut + perp * side * 420;
          }
        } else if (rank == 4) {
          // SECOND CUTTER: lays a second wall, closer to him and on the other side (double wall)
          var cut = ph + pdir * (preySp * 1.1 + 180);
          cut = Offset(cut.dx.clamp(250.0, worldSize - 250), cut.dy.clamp(250.0, worldSize - 250));
          final dc = (cut - h).distance;
          if (dc > 240) {
            aim = cut;
            hardBoost = dc < 800 && dist > 250;
          } else {
            aim = cut - perp * side * 380;
          }
        } else {
          aim = pred;
          hardBoost = dist < 450;
        }
        if (prey.shieldT > 1.0) {
          // he has a shield: do NOT crash into him. Wait around him and strike the moment it ends
          if (dist < 380) {
            aim = h + (h - ph); // too close: back off
          } else if (dist < 560) {
            aim = ph + perp * side * 450; // circle around him
          } else {
            aim = pred;
          }
          hardBoost = dist > 900;
        }
      }
      var a = atan2(aim.dy - h.dy, aim.dx - h.dx);
      if (dist < 100) {
        // too close to the head: swing around instead of crashing head-on
        final toHead = atan2(ph.dy - h.dy, ph.dx - h.dx);
        final diff = wrapAngle(toHead - s.angle);
        if (diff.abs() < 0.9) a = s.angle + (diff >= 0 ? -1.2 : 1.2);
      }
      s.target = a;
      final human = prey.isPlayer || prey.remote;
      if (human && dist > 450) s.speedMul = chaseSpeed; // a little faster when running down a player
      final wantBoost = hardHunt
          ? (hardBoost && s.len > 18) // boost only for the job of its role (get in front / finish the cut)
          : ((dist < boostNear && s.len > 18) || (farBoost && human && dist < 1800 && s.len > 22));
      s.boosting = wantBoost && wrapAngle(a - s.angle).abs() < (hardHunt ? 1.3 : 0.8);
      return;
    }

    s.huntT = 0;
    // 5) no prey: look for food
    if (s.aiTimer <= 0) {
      s.aiTimer = 0.4 + rnd.nextDouble() * 0.8;
      Food? bestFood;
      double bd = 350;
      for (final f in foods) {
        final d = (f.pos - h).distance;
        if (d < bd) {
          bd = d;
          bestFood = f;
        }
      }
      if (bestFood != null) {
        s.target = atan2(bestFood.pos.dy - h.dy, bestFood.pos.dx - h.dx);
      } else {
        s.target = s.angle + rnd.nextDouble() * 2 - 1;
      }
    }
  }

  // ---------------------------------------------------------------- HARD bots: smart body dodge
  // free space around point q = distance to the nearest body of any other snake (or the map wall), capped
  double _clear(Offset q, Snake self, double cap) {
    double best = min(cap, min(min(q.dx, q.dy), min(worldSize - q.dx, worldSize - q.dy)));
    for (final o in snakes) {
      if (o == self || !o.alive) continue;
      if (q.dx < o.minX - cap || q.dx > o.maxX + cap || q.dy < o.minY - cap || q.dy > o.maxY + cap) continue;
      final sp = max(o.spacing, 1.0);
      final pts = o.body;
      int i = 0;
      while (i < pts.length) {
        final dx = pts[i].dx - q.dx, dy = pts[i].dy - q.dy;
        final d = sqrt(dx * dx + dy * dy) - o.radius;
        if (d < best) best = d;
        final skip = ((d - best) / sp).floor(); // far points cannot be closer than the best one so far
        i += skip > 1 ? skip : 1;
      }
    }
    return best;
  }

  // true = a body is in front of this bot and it has to turn away now
  bool _hardAvoid(Snake s, Snake? prey) {
    final h = s.head;
    for (final o in snakes) {
      if (o == s || !o.alive) continue;
      // body of the player is thick when he is big, so keep more distance from him
      final margin = o == prey ? 26 + o.radius * 0.5 : 70 + min(s.len, 300.0) * 0.25;
      final lim = s.radius + o.radius + margin;
      // the WHOLE body counts, a long body can be very close even when its head is far away
      if (h.dx < o.minX - lim - 40 || h.dx > o.maxX + lim + 40 || h.dy < o.minY - lim - 40 || h.dy > o.maxY + lim + 40) continue;
      final lim2 = lim * lim;
      final sp = max(o.spacing, 1.0);
      final pts = o.body;
      int i = o == prey ? 4 : 0; // only the head area of the prey is ignored (so we can still cut in front of it)
      while (i < pts.length) {
        final dx = pts[i].dx - h.dx, dy = pts[i].dy - h.dy;
        final d2 = dx * dx + dy * dy;
        if (d2 < lim2) {
          if (wrapAngle(atan2(dy, dx) - s.angle).abs() < 1.7) {
            _dodge(s, lim);
            return true;
          }
          i++;
          continue;
        }
        final skip = ((sqrt(d2) - lim) / sp).floor(); // body points are at most one spacing apart
        i += skip > 1 ? skip : 1;
      }
    }
    return false;
  }

  // turn to the side that has the most free space (also looks at the map walls); big U-turn only if needed
  void _dodge(Snake s, double lim) {
    final h = s.head;
    final probe = lim * 1.2 + 40;
    double bestA = s.angle, bestScore = -1e9;
    for (final da in const [-1.3, -0.7, 0.7, 1.3, -2.3, 2.3]) {
      final a = s.angle + da;
      final q = h + Offset(cos(a), sin(a)) * probe;
      final score = _clear(q, s, 500) - da.abs() * 15;
      if (score > bestScore) {
        bestScore = score;
        bestA = a;
      }
    }
    s.target = bestA;
    s.turnMul = 2.0; // turn sharply
    s.speedMul = 1.0;
  }

  void _assignAttackers(double dt) {
    _slotAcc += dt;
    if (_slotAcc < 0.4) return;
    _slotAcc = 0;
    attackers.clear();
    final oldRank = Map<int, int>.from(attackRank);
    attackRank.clear();
    final humans = snakes.where((s) => s.alive && (s.isPlayer || s.remote)).toList();
    if (humans.isEmpty) return;
    final cands = <MapEntry<double, Snake>>[];
    for (final s in snakes) {
      if (!s.alive || s.isPlayer || s.remote || s.aggr <= 0.5 || s.coolT > 0) continue;
      double best = double.infinity;
      for (final hm in humans) {
        final d = (hm.head - s.head).distance;
        if (d < best) best = d;
      }
      final range = s.len > 100 ? chaseRange * 1.3 : chaseRange;
      if (best <= range) cands.add(MapEntry(best, s));
    }
    cands.sort((a, b) => a.key.compareTo(b.key));
    final k = maxHunters * humans.length;
    final chosen = <int>[];
    for (int i = 0; i < cands.length && i < k; i++) {
      attackers.add(cands[i].value.id);
      chosen.add(cands[i].value.id);
    }
    final used = <int>{};
    for (final id in chosen) {
      final r = oldRank[id];
      if (r != null && r < k && !used.contains(r)) {
        attackRank[id] = r; // keeps its old job
        used.add(r);
      }
    }
    int free = 0;
    for (final id in chosen) {
      if (attackRank.containsKey(id)) continue;
      while (used.contains(free)) {
        free++;
      }
      attackRank[id] = free;
      used.add(free);
    }
  }

  void _update(double dt) {
    _frame++;
    graceT = max(0.0, graceT - dt);
    _assignAttackers(dt);
    for (final s in snakes) {
      if (!s.alive) {
        if (s.remote) {
          if (s.respawnReq) {
            s.respawnReq = false;
            s.reset(randomPos(worldSize * 0.2));
            graceT = max(graceT, 5.0);
          }
        } else if (!s.isPlayer) {
          s.respawn -= dt;
          if (s.respawn <= 0) {
            s.reset(randomPos());
            s.skin = rnd.nextInt(skinNames.length);
            s.color = palette[rnd.nextInt(palette.length)];
            s.aggr = newAggr();
            s.shieldT = 3;
            if (difficulty == 2) s.grow(35 + rnd.nextDouble() * 40);
          }
        }
        continue;
      }
      s.speedT = max(0, s.speedT - dt);
      s.magnetT = max(0, s.magnetT - dt);
      s.shieldT = max(0, s.shieldT - dt);
      if (s.isPlayer) {
        if (joyActive && joy.distance > 8) {
          s.target = atan2(joy.dy, joy.dx);
        } else if (hasTouchSteer) {
          s.target = touchAngle;
        } else if (hasPointer && size != Size.zero) {
          s.target = atan2(pointer.dy - size.height / 2, pointer.dx - size.width / 2);
        }
        s.turnMul = (hasTouchSteer && !joystick) ? 1.35 : 1.0; // touch steering also turns a bit faster
        s.boosting = boostHeld;
      } else if (s.remote) {
        s.target = s.netTarget;
        s.boosting = s.netBoost;
      } else {
        _ai(s, dt);
      }
      if (s.len <= 12) s.boosting = false;
      s.move(dt);
      if (s.boosting) {
        s.len -= ((s.isPlayer || s.remote) ? 5.0 : botBoostCost) * dt;
        s.dropTimer += dt;
        if (s.dropTimer > 0.3) {
          s.dropTimer = 0;
          foods.add(Food(s.body.last, 8, rnd.nextInt(foodTypes)));
        }
      }
    }

    // LAG FIX: body bounding boxes (after everybody moved / respawned) for fast collision + drawing checks
    for (final s in snakes) {
      if (s.alive) s.updateBounds();
    }

    // eat food: foods are put in a coarse grid, so every snake only checks the foods near its head
    const gc = 200.0;
    final grid = _foodGrid;
    for (final l in grid.values) {
      l.clear(); // LAG FIX: reuse the lists instead of creating new ones every frame
    }
    for (final f in foods) {
      final key = (f.pos.dx / gc).floor() * 1000 + (f.pos.dy / gc).floor();
      (grid[key] ??= <Food>[]).add(f);
    }
    for (final s in snakes) {
      if (!s.alive) continue;
      final reach = s.radius + 8;
      final range = s.magnetT > 0 ? 270.0 : reach + 16;
      final x0 = ((s.head.dx - range) / gc).floor(), x1 = ((s.head.dx + range) / gc).floor();
      final y0 = ((s.head.dy - range) / gc).floor(), y1 = ((s.head.dy + range) / gc).floor();
      for (int cx = x0; cx <= x1; cx++) {
        for (int cy = y0; cy <= y1; cy++) {
          final cell = grid[cx * 1000 + cy];
          if (cell == null) continue;
          for (final f in cell) {
            if (f.eaten) continue;
            final d = s.head - f.pos;
            var dist = d.distance;
            if (s.magnetT > 0 && dist < 260 && dist > 1) {
              f.pos += d / dist * min(dist, 650 * dt);
              dist = (s.head - f.pos).distance;
            }
            if (dist < reach + f.r * 0.5) {
              f.eaten = true;
              s.len += f.r * 0.07 * ((s.isPlayer || s.remote) ? 1.0 : botGrowth);
              if (s.isPlayer) Sfx.eat();
            }
          }
        }
      }
      // power-ups
      for (int i = powers.length - 1; i >= 0; i--) {
        final pu = powers[i];
        if ((pu.pos - s.head).distance < s.radius + 24) {
          if (pu.type == 0) s.speedT = 8;
          if (pu.type == 1) s.magnetT = 8;
          if (pu.type == 2) s.shieldT = 8;
          powers.removeAt(i);
          if (s.isPlayer) Sfx.power();
        }
      }
    }

    foods.removeWhere((f) => f.eaten);

    // collisions
    for (final s in snakes) {
      if (!s.alive) continue;
      final h = s.head;
      bool dead = h.dx < 0 || h.dx > worldSize || h.dy < 0 || h.dy > worldSize;
      if (!dead && s.shieldT <= 0) {
        for (final o in snakes) {
          if (o == s || !o.alive) continue;
          final limit = min(s.radius * 0.7, 10.0) + o.radius * 0.8;
          // LAG FIX: head is outside the other snake's bounding box -> it cannot touch it
          if (h.dx < o.minX - limit || h.dx > o.maxX + limit || h.dy < o.minY - limit || h.dy > o.maxY + limit) continue;
          final limit2 = limit * limit;
          final sp = max(o.spacing, 1.0);
          final pts = o.body;
          int bi = 0;
          while (bi < pts.length) {
            final dx = pts[bi].dx - h.dx, dy = pts[bi].dy - h.dy;
            final d2 = dx * dx + dy * dy;
            if (d2 < limit2) {
              dead = true;
              o.kills++;
              if (o.isPlayer) Sfx.kill();
              break;
            }
            // body points are at most one spacing apart, so far points can be skipped safely
            final skip = ((sqrt(d2) - limit) / sp).floor();
            bi += skip > 1 ? skip : 1;
          }
          if (dead) break;
        }
      }
      if (dead) _kill(s);
    }

    if (foods.length > foodCount * 2) foods.removeRange(0, foods.length - foodCount * 2); // never let food pile up
    while (foods.length < foodCount) {
      foods.add(newFood());
    }
    while (powers.length < powerCount) {
      powers.add(PowerUp(randomPos(100), rnd.nextInt(3)));
    }

    _boardAcc += dt;
    if (_boardAcc >= 0.3) {
      _boardAcc = 0;
      _boardCache = (snakes.where((s) => s.alive).toList()..sort((a, b) => b.len.compareTo(a.len)))
          .take(8)
          .map<List<dynamic>>((s) => [s.name, s.score, s.isPlayer])
          .toList();
    }

    if (player.alive) cam = cam + (player.head - cam) * min(1.0, dt * 8);
  }

  // ================================================================ UI
  @override
  Widget build(BuildContext context) {
    final wantMusic = screen == Screen.home ? 1 : 2;
    if (wantMusic != Music.want) Music.play(wantMusic);
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B16),
      body: Focus(
        focusNode: gameFocus,
        onKeyEvent: (_, e) {
          if (screen == Screen.play && e.logicalKey == LogicalKeyboardKey.space) {
            boostHeld = e is! KeyUpEvent;
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: screen == Screen.home ? _home() : _game(),
      ),
    );
  }

  // ---------------------------------------------------------------- NEW HOME UI
  Widget _glass({required Widget child, EdgeInsets padding = const EdgeInsets.all(14), double radius = 22, Color? border}) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.07),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border ?? Colors.white.withOpacity(0.14), width: 1.5),
      ),
      child: child,
    );
  }

  Widget _statCard(IconData icon, Color c, String title, int score, int kills) {
    return Expanded(
      child: _glass(
        child: Row(children: [
          Icon(icon, color: c, size: 30),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w700)),
            Text('$score', style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900)),
            Text('$kills kills', style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        ]),
      ),
    );
  }

  Widget _dockItem(IconData icon, Color c, String label, String sub, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.withOpacity(0.16),
              border: Border.all(color: c.withOpacity(0.8), width: 2),
              boxShadow: [BoxShadow(color: c.withOpacity(0.35), blurRadius: 14)],
            ),
            child: Icon(icon, color: c, size: 28),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
          Text(sub, style: const TextStyle(color: Colors.white54, fontSize: 11)),
        ]),
      ),
    );
  }

  Widget _home() {
    return Stack(children: [
      Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: HomeBgPainter(homeClock)))),
      SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                controller: homeScroll,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: box.maxHeight - 24),
                  child: Column(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                    // ---- title
                    Column(children: [
                      const Text('EAT  •  GROW  •  SURVIVE',
                          style: TextStyle(color: kCyan, fontSize: 12, letterSpacing: 4, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('CENTIPEDE',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 50,
                                height: 1.0,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 4,
                                shadows: [Shadow(color: kCyan.withOpacity(0.7), blurRadius: 26)])),
                      ),
                      ShaderMask(
                        shaderCallback: (r) => const LinearGradient(colors: [kLime, kCyan]).createShader(r),
                        child: const Text('FEAST',
                            style: TextStyle(color: Colors.white, fontSize: 58, height: 0.95, fontWeight: FontWeight.w900, letterSpacing: 10)),
                      ),
                    ]),
                    const SizedBox(height: 14),
                    // ---- snake preview card
                    GestureDetector(
                      onTap: _skinSheet,
                      child: _glass(
                        padding: EdgeInsets.zero,
                        radius: 28,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(26),
                          child: SizedBox(
                            height: 130,
                            child: Stack(children: [
                              Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: SnakePreviewPainter(homeClock, skin, playerColor)))),
                              Positioned(
                                left: 16,
                                top: 12,
                                child: Text('${skinNames[skin].toUpperCase()} SKIN',
                                    style: const TextStyle(color: Colors.white60, fontSize: 11, letterSpacing: 2, fontWeight: FontWeight.w700)),
                              ),
                              Positioned(
                                right: 12,
                                top: 10,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(14)),
                                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                                    Icon(Icons.edit, size: 13, color: Colors.white70),
                                    SizedBox(width: 4),
                                    Text('CHANGE', style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w700)),
                                  ]),
                                ),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    // ---- nickname
                    TextField(
                      controller: nameCtrl,
                      maxLength: 15,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                      decoration: InputDecoration(
                        counterText: '',
                        hintText: 'Nickname (optional)',
                        hintStyle: const TextStyle(color: Colors.white38),
                        prefixIcon: const Icon(Icons.person_outline, color: Colors.white38),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.07),
                        contentPadding: const EdgeInsets.symmetric(vertical: 14),
                        enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(30), borderSide: const BorderSide(color: Colors.white24, width: 1.5)),
                        focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(30), borderSide: const BorderSide(color: kLime, width: 2)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // ---- difficulty
                    Row(children: [
                      for (int i = 0; i < 3; i++)
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              setState(() => difficulty = i);
                              _save();
                            },
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              height: 42,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(21),
                                color: difficulty == i ? [kLime, Colors.amber, kPink][i].withOpacity(0.2) : Colors.white.withOpacity(0.06),
                                border: Border.all(color: difficulty == i ? [kLime, Colors.amber, kPink][i] : Colors.white24, width: 2),
                              ),
                              child: Text(diffNames[i].toUpperCase(),
                                  style: TextStyle(
                                      color: difficulty == i ? [kLime, Colors.amber, kPink][i] : Colors.white60,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 1.5,
                                      fontSize: 13)),
                            ),
                          ),
                        ),
                    ]),
                    const SizedBox(height: 14),
                    // ---- play buttons
                    GestureDetector(
                      onTap: () => startGame(25),
                      child: Container(
                        width: double.infinity,
                        height: 72,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(36),
                          gradient: const LinearGradient(colors: [kLime, Color(0xFF1DE9B6)]),
                          boxShadow: [BoxShadow(color: kLime.withOpacity(0.5), blurRadius: 26, offset: const Offset(0, 6))],
                        ),
                        child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(Icons.play_arrow_rounded, size: 44, color: Color(0xFF0B2A12)),
                          SizedBox(width: 6),
                          Text('PLAY', style: TextStyle(color: Color(0xFF0B2A12), fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 4)),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: () => startGame(40),
                      child: Container(
                        width: double.infinity,
                        height: 50,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(25),
                          border: Border.all(color: kPink, width: 2),
                          color: kPink.withOpacity(0.10),
                        ),
                        child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(Icons.local_fire_department, color: kPink),
                          SizedBox(width: 8),
                          Text('HARDCORE  •  40 BOTS',
                              style: TextStyle(color: kPink, fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: 1.5)),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: _friendsSheet,
                      child: Container(
                        width: double.infinity,
                        height: 50,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(25),
                          border: Border.all(color: kCyan, width: 2),
                          color: kCyan.withOpacity(0.10),
                        ),
                        child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(Icons.wifi, color: kCyan),
                          SizedBox(width: 8),
                          Text('PLAY WITH FRIENDS',
                              style: TextStyle(color: kCyan, fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: 1.5)),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // ---- stats
                    Row(children: [
                      _statCard(Icons.history, kCyan, 'LAST RUN', lastScore, lastKills),
                      const SizedBox(width: 12),
                      _statCard(Icons.emoji_events, Colors.amber, 'BEST', bestScore, bestKills),
                    ]),
                    const SizedBox(height: 16),
                    // ---- dock
                    _glass(
                      radius: 32,
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                      child: Row(children: [
                        _dockItem(Icons.palette, playerColor, 'Skins', skinNames[skin], _skinSheet),
                        _dockItem(Icons.map_rounded, kCyan, 'Map', mapNames[mapChoice], _mapSheet),
                        _dockItem(Icons.tune, kViolet, 'Settings', 'Sound & more', _settingsSheet),
                      ]),
                    ),
                    const SizedBox(height: 10),
                    const AdBanner(),
                    const SizedBox(height: 6),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
      _moreBelowHint(),
    ]);
  }

  // ---------------------------------------------------------------- bottom sheets
  void _sheet(String title, List<Widget> Function(StateSetter) build) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => Container(
          decoration: BoxDecoration(
            color: const Color(0xFF181236),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
            border: Border.all(color: Colors.white12),
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Center(
                    child: Container(
                        width: 44, height: 5, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(3)))),
                const SizedBox(height: 16),
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900)),
                const SizedBox(height: 16),
                ...build(setD),
              ]),
            ),
          ),
        ),
      ),
    ).then((_) => _save());
  }

  Widget _label(String t) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 10),
    child: Text(t, style: const TextStyle(color: Colors.white54, fontSize: 12, letterSpacing: 2, fontWeight: FontWeight.w800)),
  );

  void _skinSheet() {
    _sheet('Your Centipede', (setD) {
      final tw = (min(MediaQuery.of(context).size.width, 520) - 52) / 2;
      return [
        Container(
          height: 80,
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(20)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: CustomPaint(painter: SnakePreviewPainter(homeClock, skin, playerColor), size: Size.infinite),
          ),
        ),
        _label('COLOR'),
        Wrap(spacing: 12, runSpacing: 12, children: [
          for (int i = 0; i < colorChoices.length; i++)
            GestureDetector(
              onTap: () {
                setState(() => colorIdx = i);
                setD(() {});
              },
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: colorChoices[i],
                  shape: BoxShape.circle,
                  border: Border.all(color: colorIdx == i ? Colors.white : Colors.transparent, width: 3),
                  boxShadow: colorIdx == i ? [BoxShadow(color: colorChoices[i].withOpacity(0.6), blurRadius: 12)] : null,
                ),
              ),
            ),
        ]),
        _label('SKIN'),
        Wrap(spacing: 12, runSpacing: 12, children: [
          for (int k = 0; k < skinNames.length; k++)
            GestureDetector(
              onTap: () {
                setState(() => skin = k);
                setD(() {});
              },
              child: Container(
                width: tw,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: skin == k ? kLime.withOpacity(0.14) : Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: skin == k ? kLime : Colors.white12, width: 2),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(skinNames[k], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Row(children: [
                    for (int i = 0; i < 7; i++)
                      Container(
                        width: 14,
                        height: 14,
                        margin: const EdgeInsets.only(right: 2),
                        decoration: BoxDecoration(color: skinColor(k, playerColor, i, 7), shape: BoxShape.circle),
                      ),
                  ]),
                ]),
              ),
            ),
        ]),
      ];
    });
  }

  void _mapSheet() {
    const desc = ['Fast & furious', 'Balanced fun', 'Epic hunt'];
    _sheet('Choose Map', (setD) {
      return [
        for (int i = 0; i < mapSizes.length; i++)
          GestureDetector(
            onTap: () {
              setState(() => mapChoice = i);
              setD(() {});
            },
            child: Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: mapChoice == i ? kCyan.withOpacity(0.12) : Colors.white.withOpacity(0.06),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: mapChoice == i ? kCyan : Colors.white12, width: 2),
              ),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(width: 92, height: 64, child: CustomPaint(painter: MapPreviewPainter(i))),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${mapNames[i]}  •  ${mapThemes[i]}',
                        style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                    Text('${mapSizes[i].toInt()} x ${mapSizes[i].toInt()}  •  ${desc[i]}',
                        style: const TextStyle(color: Colors.white54, fontSize: 13)),
                  ]),
                ),
                if (mapChoice == i) const Icon(Icons.check_circle, color: kCyan),
              ]),
            ),
          ),
      ];
    });
  }

  Widget _sw(String t, IconData ic, bool v, void Function(bool) f, StateSetter setD) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.06), borderRadius: BorderRadius.circular(18)),
      child: SwitchListTile(
        secondary: Icon(ic, color: Colors.white70),
        title: Text(t, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        value: v,
        activeColor: kLime,
        onChanged: (x) {
          setState(() => f(x));
          setD(() {});
        },
      ),
    );
  }

  void _settingsSheet() {
    _sheet('Settings', (setD) {
      return [
        _sw('Music', Icons.music_note, music, (x) {
          music = x;
          Music.enabled = x;
          Music.sync();
        }, setD),
        _sw('Sound effects', Icons.volume_up, sound, (x) {
          sound = x;
          Sfx.enabled = x;
        }, setD),
        _sw('Joystick  (off = touch & drag screen)', Icons.gamepad, joystick, (x) => joystick = x, setD),
        _sw('Direction arrow', Icons.navigation, showArrow, (x) => showArrow = x, setD),
        _sw('Show names', Icons.badge_outlined, showNames, (x) => showNames = x, setD),
        _sw('Show leaderboard', Icons.leaderboard, showBoard, (x) => showBoard = x, setD),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: kPink, side: const BorderSide(color: kPink)),
          onPressed: () {
            setState(() {
              bestScore = 0;
              bestKills = 0;
              lastScore = 0;
              lastKills = 0;
            });
            _save();
            setD(() {});
          },
          icon: const Icon(Icons.delete_outline),
          label: const Text('Reset best score'),
        ),
      ];
    });
  }

  // ================================================================ WiFi multiplayer (host = server)
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<String> _localIp() async {
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      final all = <String>[
        for (final i in ifs)
          for (final a in i.addresses) a.address
      ];
      for (final ip in all) {
        if (ip.startsWith('192.168.')) return ip;
      }
      for (final ip in all) {
        if (RegExp(r'^172\.(1[6-9]|2[0-9]|3[01])\.').hasMatch(ip)) return ip;
      }
      for (final ip in all) {
        if (ip.startsWith('10.')) return ip;
      }
      return all.isNotEmpty ? all.first : 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  Future<void> _startHost() async {
    HttpServer srv;
    try {
      srv = await HttpServer.bind(InternetAddress.anyIPv4, kPort);
    } catch (e) {
      _toast('Could not start the room: $e');
      return;
    }
    hostIp = await _localIp();
    startGame(10, hosting: true);
    server = srv;
    srv.listen((req) async {
      try {
        if (WebSocketTransformer.isUpgradeRequest(req)) {
          final w = await WebSocketTransformer.upgrade(req);
          _onClient(w);
        } else {
          req.response
            ..statusCode = 200
            ..write('Snake Feast room');
          await req.response.close();
        }
      } catch (_) {}
    });
  }

  void _onClient(WebSocket w) {
    if (conns.length >= 6) {
      w.close();
      return;
    }
    NetConn? conn;
    w.listen((data) {
      try {
        final m = jsonDecode(data as String) as Map<String, dynamic>;
        final t = m['t'];
        if (t == 'hi' && conn == null) {
          final id = nextId++;
          var nm = ((m['name'] as String?) ?? '').trim();
          if (nm.length > 15) nm = nm.substring(0, 15);
          if (nm.isEmpty) nm = 'Friend$id';
          final s = Snake(
            isPlayer: false,
            name: nm,
            color: Color(m['color'] as int),
            skin: (m['skin'] as num).toInt().clamp(0, skinNames.length - 1),
            start: randomPos(worldSize * 0.2),
          );
          s.id = id;
          s.remote = true;
          snakes.add(s);
          conn = NetConn(w, s);
          conns[id] = conn!;
          w.add(jsonEncode({'t': 'w', 'id': id, 'world': worldSize}));
        } else if (t == 'in' && conn != null) {
          conn!.snake.netTarget = (m['a'] as num).toDouble();
          conn!.snake.netBoost = m['b'] == 1;
        } else if (t == 'respawn' && conn != null) {
          conn!.snake.respawnReq = true;
        }
      } catch (_) {}
    }, onDone: () => _dropClient(conn), onError: (_) => _dropClient(conn));
  }

  void _dropClient(NetConn? c) {
    if (c == null) return;
    if (conns.remove(c.snake.id) == null) return;
    if (c.snake.alive) _kill(c.snake);
    snakes.remove(c.snake);
    if (mounted) setState(() {});
  }

  Map<String, dynamic> _snapshot(Snake me, List<dynamic> lb, List<dynamic> mm) {
    final h = me.head;
    final sn = <List<dynamic>>[];
    for (final s in snakes) {
      if (s != me) {
        if (!s.alive) continue;
        bool near = false;
        for (int i = 0; i < s.body.length; i += 4) {
          if ((s.body[i] - h).distance < 1500) {
            near = true;
            break;
          }
        }
        if (!near) continue;
      }
      final pts = <int>[];
      if (s.alive) {
        for (final p in s.body) {
          pts.add(p.dx.round());
          pts.add(p.dy.round());
        }
      }
      sn.add([
        s.id,
        s.name,
        s.color.value,
        s.skin,
        s.alive ? 1 : 0,
        double.parse(s.len.toStringAsFixed(1)),
        s.kills,
        double.parse(s.speedT.toStringAsFixed(1)),
        double.parse(s.magnetT.toStringAsFixed(1)),
        double.parse(s.shieldT.toStringAsFixed(1)),
        s.boosting ? 1 : 0,
        double.parse(s.angle.toStringAsFixed(2)),
        pts,
      ]);
    }
    final f = <List<num>>[];
    for (final fd in foods) {
      if ((fd.pos - h).distance < 1300) {
        f.add([fd.pos.dx.round(), fd.pos.dy.round(), double.parse(fd.r.toStringAsFixed(1)), fd.type]);
      }
    }
    final p = <List<num>>[];
    for (final pu in powers) {
      if ((pu.pos - h).distance < 1300) {
        p.add([pu.pos.dx.round(), pu.pos.dy.round(), pu.type]);
      }
    }
    return {'t': 's', 'me': me.id, 'sn': sn, 'f': f, 'p': p, 'lb': lb, 'mm': mm};
  }

  void _hostBroadcast(double dt) {
    if (conns.isEmpty) return;
    _sendAcc += dt;
    if (_sendAcc < 0.05) return;
    _sendAcc = 0;
    final alive = snakes.where((s) => s.alive).toList();
    final sorted = [...alive]..sort((a, b) => b.len.compareTo(a.len));
    final lb = [
      for (final s in sorted.take(8)) [s.name, s.score, s.id]
    ];
    final mm = [
      for (final s in alive) [s.head.dx.round(), s.head.dy.round(), s.color.value, s.id]
    ];
    for (final c in conns.values.toList()) {
      try {
        c.ws.add(jsonEncode(_snapshot(c.snake, lb, mm)));
      } catch (_) {}
    }
  }

  Future<String?> _joinGame(String ipRaw) async {
    final ip = ipRaw.trim();
    if (ip.isEmpty) return 'Enter the host IP address first.';
    try {
      _leaveNet();
      final w = await WebSocket.connect('ws://$ip:$kPort').timeout(const Duration(seconds: 5));
      clientWs = w;
      role = NetRole.client;
      netSnakes.clear();
      snakes.clear();
      foods.clear();
      powers.clear();
      netBoard = [];
      netDots = [];
      firstSnap = true;
      myNetId = -1;
      hostIp = ip;
      clientTarget = 0;
      final nick = nameCtrl.text.trim();
      player = Snake(
        isPlayer: true,
        name: nick.isEmpty ? 'You' : nick,
        color: playerColor,
        skin: skin,
        start: const Offset(-9000, -9000),
      );
      cam = player.head;
      w.add(jsonEncode({'t': 'hi', 'name': nick, 'color': playerColor.value, 'skin': skin}));
      w.listen((data) {
        try {
          final m = jsonDecode(data as String) as Map<String, dynamic>;
          if (m['t'] == 'w') {
            myNetId = m['id'] as int;
            worldSize = (m['world'] as num).toDouble();
          } else if (m['t'] == 's') {
            _onSnapshot(m);
          }
        } catch (_) {}
      }, onDone: _hostLeft, onError: (_) => _hostLeft());
      hasPointer = false;
      hasTouchSteer = false;
      touchActive = false;
      touchAnchor = null;
      boostHeld = false;
      joyActive = false;
      joy = Offset.zero;
      _save();
      setState(() => screen = Screen.play);
      gameFocus.requestFocus();
      return null;
    } catch (e) {
      role = NetRole.none;
      clientWs = null;
      return "Couldn't connect. Check the IP, and that both phones are on the same WiFi.";
    }
  }

  void _onSnapshot(Map<String, dynamic> m) {
    myNetId = m['me'] as int;
    final seen = <int>{};
    for (final e in (m['sn'] as List)) {
      final id = e[0] as int;
      seen.add(id);
      final isMe = id == myNetId;
      var s = netSnakes[id];
      if (s == null) {
        s = Snake(isPlayer: isMe, name: e[1] as String, color: Color(e[2] as int), skin: e[3] as int, start: Offset.zero);
        s.id = id;
        netSnakes[id] = s;
      }
      final wasAlive = s.alive;
      final oldLen = s.len;
      final oldKills = s.kills;
      s.name = e[1] as String;
      s.color = Color(e[2] as int);
      s.skin = e[3] as int;
      s.alive = e[4] == 1;
      s.len = (e[5] as num).toDouble();
      s.kills = e[6] as int;
      s.speedT = (e[7] as num).toDouble();
      s.magnetT = (e[8] as num).toDouble();
      s.shieldT = (e[9] as num).toDouble();
      s.boosting = e[10] == 1;
      s.angle = (e[11] as num).toDouble();
      final raw = e[12] as List;
      if (raw.isNotEmpty) {
        final net = <Offset>[];
        for (int i = 0; i + 1 < raw.length; i += 2) {
          net.add(Offset((raw[i] as num).toDouble(), (raw[i + 1] as num).toDouble()));
        }
        s.net = net;
        if (s.body.length != net.length || (s.body.first - net.first).distance > 300) {
          s.body
            ..clear()
            ..addAll(net);
        }
      }
      if (isMe) {
        player = s;
        if (wasAlive && !s.alive) {
          _recordPlayer();
          Sfx.die();
          AdsManager.onGameOver();
        } else if (s.alive && s.len > oldLen + 0.05) {
          Sfx.eat();
        }
        if (s.kills > oldKills) Sfx.kill();
      }
    }
    netSnakes.removeWhere((id, _) => !seen.contains(id));
    snakes
      ..clear()
      ..addAll(netSnakes.values);

    foods
      ..clear()
      ..addAll((m['f'] as List).map((r) => Food(Offset((r[0] as num).toDouble(), (r[1] as num).toDouble()), (r[2] as num).toDouble(), r[3] as int)));
    powers
      ..clear()
      ..addAll((m['p'] as List).map((r) => PowerUp(Offset((r[0] as num).toDouble(), (r[1] as num).toDouble()), r[2] as int)));
    netBoard = (m['lb'] as List).map<List<dynamic>>((r) => [r[0], r[1], r[2] == myNetId]).toList();
    netDots = (m['mm'] as List)
        .map<MiniDot>((r) => MiniDot(Offset((r[0] as num).toDouble(), (r[1] as num).toDouble()), Color(r[2] as int), r[3] == myNetId))
        .toList();
  }

  double? _steerTarget() {
    if (joyActive && joy.distance > 8) return atan2(joy.dy, joy.dx);
    if (hasTouchSteer) return touchAngle;
    if (hasPointer && size != Size.zero) return atan2(pointer.dy - size.height / 2, pointer.dx - size.width / 2);
    return null;
  }

  void _clientUpdate(double dt) {
    final k = min(1.0, dt * 14);
    for (final s in snakes) {
      final n = s.net;
      if (n == null || n.isEmpty) continue;
      if (s.body.length != n.length) {
        s.body
          ..clear()
          ..addAll(n);
      } else {
        for (int i = 0; i < n.length; i++) {
          s.body[i] = Offset.lerp(s.body[i], n[i], k)!;
        }
      }
      s.updateBounds(); // LAG FIX: keeps the drawing culling correct on the client too
    }
    if (player.alive && player.body.isNotEmpty && snakes.contains(player)) {
      if (firstSnap) {
        cam = player.head;
        firstSnap = false;
      } else {
        cam = cam + (player.head - cam) * min(1.0, dt * 8);
      }
    }
    final t = _steerTarget();
    if (t != null) clientTarget = t;
    _sendAcc += dt;
    if (_sendAcc >= 0.05) {
      _sendAcc = 0;
      try {
        clientWs?.add(jsonEncode({'t': 'in', 'a': double.parse(clientTarget.toStringAsFixed(2)), 'b': boostHeld ? 1 : 0}));
      } catch (_) {}
    }
  }

  void _hostLeft() {
    if (role != NetRole.client) return;
    AdsManager.cancelPendingInterstitial();
    _leaveNet();
    if (!mounted) return;
    setState(() => screen = Screen.home);
    _toast('The host left the game.');
  }

  void _leaveNet() {
    for (final c in conns.values) {
      try {
        c.ws.close();
      } catch (_) {}
    }
    conns.clear();
    try {
      server?.close(force: true);
    } catch (_) {}
    server = null;
    final w = clientWs;
    clientWs = null;
    role = NetRole.none;
    try {
      w?.close();
    } catch (_) {}
    netSnakes.clear();
  }

  void _revive() {
    AdsManager.cancelPendingInterstitial();
    if (!mounted || role == NetRole.client) return;
    setState(() {
      revivesLeft = max(0, revivesLeft - 1);
      player.reset(randomPos(worldSize * 0.2));
      player.len = 40; // reward: start longer
      player.shieldT = 5; // reward: 5 seconds of shield
      graceT = 6;
      cam = player.head;
    });
  }

  void _playAgain() {
    AdsManager.cancelPendingInterstitial();
    if (role == NetRole.client) {
      try {
        clientWs?.add(jsonEncode({'t': 'respawn'}));
      } catch (_) {}
    } else if (role == NetRole.host) {
      player.reset(randomPos(worldSize * 0.2));
      graceT = 6;
      revivesLeft = kMaxRevives;
      cam = player.head;
    } else {
      startGame(botCount);
    }
  }

  List<MiniDot> mmDots() {
    if (role == NetRole.client) return netDots;
    return [
      for (final s in snakes)
        if (s.alive) MiniDot(s.head, s.color, s.isPlayer)
    ];
  }

  // ---------------------------------------------------------------- friends sheet
  void _friendsSheet() {
    netMsg = null;
    netBusy = false;
    _sheet('Play with Friends', (setD) {
      if (kIsWeb) {
        return [
          _glass(
              child: const Text('WiFi play needs the Android / iOS / Windows app. It does not work inside a web browser.',
                  style: TextStyle(color: Colors.white70))),
        ];
      }
      return [
        _glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.wifi_tethering, color: kLime),
              SizedBox(width: 8),
              Text('Host a game', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 8),
            const Text('Your phone creates the room. Friends on the same WiFi (or your hotspot) join using your IP address, which shows at the top of the game screen.',
                style: TextStyle(color: Colors.white60, fontSize: 13)),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () {
                Navigator.of(context).pop();
                _startHost();
              },
              child: Container(
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  gradient: const LinearGradient(colors: [kLime, Color(0xFF1DE9B6)]),
                ),
                child: const Text('START HOSTING',
                    style: TextStyle(color: Color(0xFF0B2A12), fontWeight: FontWeight.w900, letterSpacing: 2)),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        _glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.login, color: kCyan),
              SizedBox(width: 8),
              Text('Join a game', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: ipCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: Colors.white, fontSize: 18),
              decoration: InputDecoration(
                hintText: 'Host IP  e.g. 192.168.1.5',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.dns_outlined, color: Colors.white38),
                filled: true,
                fillColor: Colors.white.withOpacity(0.07),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                enabledBorder:
                OutlineInputBorder(borderRadius: BorderRadius.circular(26), borderSide: const BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(26), borderSide: const BorderSide(color: kCyan, width: 2)),
              ),
            ),
            if (netMsg != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(netMsg!, style: const TextStyle(color: kPink, fontSize: 13)),
              ),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: netBusy
                  ? null
                  : () async {
                setD(() {
                  netBusy = true;
                  netMsg = null;
                });
                final err = await _joinGame(ipCtrl.text);
                if (!mounted) return;
                if (err != null) {
                  setD(() {
                    netBusy = false;
                    netMsg = err;
                  });
                } else {
                  netBusy = false;
                  Navigator.of(context).pop();
                }
              },
              child: Container(
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  color: kCyan.withOpacity(netBusy ? 0.4 : 1),
                ),
                child: Text(netBusy ? 'CONNECTING...' : 'JOIN',
                    style: const TextStyle(color: Color(0xFF06222B), fontWeight: FontWeight.w900, letterSpacing: 2)),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        const Text('Tip: both phones must be on the same WiFi. If it does not connect, turn on one phone\'s hotspot and connect the other phone to it.',
            style: TextStyle(color: Colors.white54, fontSize: 12)),
      ];
    });
  }

  int? _touchId; // the finger that is steering

  void _ptr(PointerEvent e) {
    if (e.kind == PointerDeviceKind.touch) {
      if (joystick) return; // joystick ON: the joystick steers, touches on the screen are ignored
      // Touch-drag steering: the place where you put your finger is the centre.
      // Moving the finger a little turns the snake. The centre follows the finger,
      // so a small swipe is always enough (no need to circle around the whole screen).
      if (e is PointerDownEvent || _touchId == null) {
        _touchId = e.pointer;
        touchAnchor = e.localPosition;
        touchActive = true;
      }
      if (e.pointer != _touchId) return;
      touchPos = e.localPosition;
      var d = touchPos - touchAnchor!;
      const reach = 60.0; // smaller = more sensitive
      if (d.distance > reach) {
        touchAnchor = touchPos - d / d.distance * reach;
        d = touchPos - touchAnchor!;
      }
      if (d.distance > 5) {
        touchAngle = atan2(d.dy, d.dx);
        hasTouchSteer = true;
      }
      return;
    }
    hasTouchSteer = false;
    pointer = e.localPosition;
    hasPointer = true;
  }

  void _ptrUp(PointerEvent e) {
    if (e.kind == PointerDeviceKind.touch && e.pointer == _touchId) {
      _touchId = null;
      touchActive = false;
      touchAnchor = null;
    }
  }

  void _joyUpdate(PointerEvent e) {
    var v = e.localPosition - const Offset(60, 60);
    if (v.distance > 45) v = v / v.distance * 45;
    joy = v;
    joyActive = true;
  }

  void _joyEnd(PointerEvent e) {
    joyActive = false;
    joy = Offset.zero;
  }

  Widget _chip(IconData ic, Color c, double t) => Container(
    margin: const EdgeInsets.only(right: 8),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: c.withOpacity(0.9), borderRadius: BorderRadius.circular(20)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(ic, size: 16, color: Colors.white),
      const SizedBox(width: 4),
      Text('${t.ceil()}s', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
    ]),
  );

  Widget _game() {
    final List<List<dynamic>> board = role == NetRole.client ? netBoard : _boardCache;
    return LayoutBuilder(builder: (context, c) {
      size = Size(c.maxWidth, c.maxHeight);
      return Stack(children: [
        Positioned.fill(
          child: MouseRegion(
            onHover: (e) {
              hasTouchSteer = false;
              pointer = e.localPosition;
              hasPointer = true;
            },
            child: Listener(
              onPointerDown: _ptr,
              onPointerMove: _ptr,
              onPointerUp: _ptrUp,
              onPointerCancel: _ptrUp,
              child: RepaintBoundary(child: CustomPaint(painter: GamePainter(this))),
            ),
          ),
        ),
        Positioned(
          left: 12,
          top: 12,
          child: SafeArea(
            child: Row(children: [
              IconButton(
                  icon: const Icon(Icons.home, color: Colors.white),
                  onPressed: () {
                    if (player.alive) _recordPlayer();
                    AdsManager.cancelPendingInterstitial();
                    _leaveNet();
                    setState(() => screen = Screen.home);
                  }),
              Text('Score: ${player.score}   Kills: ${player.kills}',
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            ]),
          ),
        ),
        if (player.alive)
          Positioned(
            left: 16,
            top: 64,
            child: SafeArea(
              child: Row(children: [
                if (player.speedT > 0) _chip(Icons.bolt, const Color(0xFFFFA000), player.speedT),
                if (player.magnetT > 0) _chip(Icons.radar, const Color(0xFFE91E63), player.magnetT),
                if (player.shieldT > 0) _chip(Icons.shield, const Color(0xFF2196F3), player.shieldT),
              ]),
            ),
          ),
        if (role != NetRole.none)
          Positioned(
            left: 16,
            top: 104,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kCyan.withOpacity(0.6)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.wifi, size: 14, color: kCyan),
                  const SizedBox(width: 6),
                  Text(role == NetRole.host ? 'Room IP: $hostIp  •  ${conns.length + 1} players' : 'Connected to $hostIp',
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
        if (showBoard)
          Positioned(
            right: 16,
            top: 16,
            child: SafeArea(
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                const Text('Leaderboard', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
                for (final r in board)
                  Text('${r[0]}  ${r[1]}',
                      style: TextStyle(color: r[2] == true ? Colors.greenAccent : Colors.white, fontSize: 13)),
              ]),
            ),
          ),
        if (player.alive && joystick)
          Positioned(
            left: 34,
            bottom: 80,
            child: Listener(
              onPointerDown: _joyUpdate,
              onPointerMove: _joyUpdate,
              onPointerUp: _joyEnd,
              onPointerCancel: _joyEnd,
              child: SizedBox(width: 120, height: 120, child: CustomPaint(painter: JoyPainter(joy))),
            ),
          ),
        if (player.alive)
          Positioned(
            right: 24,
            bottom: 24,
            child: Listener(
              onPointerDown: (_) => boostHeld = true,
              onPointerUp: (_) => boostHeld = false,
              onPointerCancel: (_) => boostHeld = false,
              child: Container(
                width: 84,
                height: 84,
                alignment: Alignment.center,
                decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.orange.withOpacity(0.8)),
                child: const Text('BOOST', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
          ),
        if (!player.alive)
          Center(
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(16)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Game Over', style: TextStyle(color: Colors.redAccent, fontSize: 34, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text('Score: $lastScore    Kills: $lastKills', style: const TextStyle(color: Colors.white, fontSize: 18)),
                Text('Best: $bestScore', style: const TextStyle(color: Colors.amber, fontSize: 16)),
                const SizedBox(height: 16),
                if (AdsManager.supported && role != NetRole.client && revivesLeft > 0 && AdsManager.rewardAvailable) ...[
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.amber, foregroundColor: Colors.black),
                    onPressed: () => AdsManager.showRewardedInterstitial(_revive),
                    icon: const Icon(Icons.ondemand_video),
                    label: const Text('WATCH AD  •  REVIVE'),
                  ),
                  const SizedBox(height: 6),
                  Text('Reward: 5 sec shield + longer snake  •  $revivesLeft left this round',
                      style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  const SizedBox(height: 12),
                ],
                Row(mainAxisSize: MainAxisSize.min, children: [
                  ElevatedButton(onPressed: _playAgain, child: const Text('PLAY AGAIN')),
                  const SizedBox(width: 12),
                  OutlinedButton(
                      onPressed: () {
                        AdsManager.cancelPendingInterstitial();
                        _leaveNet();
                        setState(() => screen = Screen.home);
                      },
                      child: const Text('HOME')),
                ]),
              ]),
            ),
          ),
      ]);
    });
  }
}

// ================================================================ drawing helpers
void drawFood(Canvas canvas, int type, Offset pos, double r) {
  canvas.save();
  canvas.translate(pos.dx, pos.dy);
  canvas.scale(r * 1.15);
  final p = Paint()..style = PaintingStyle.fill;
  switch (type) {
    case 0: // pizza
      p.color = const Color(0xFFD98E2B);
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTRB(-1, -1, 1, -0.6), const Radius.circular(0.2)), p);
      final tri = Path()
        ..moveTo(-0.92, -0.62)
        ..lineTo(0.92, -0.62)
        ..lineTo(0, 1.05)
        ..close();
      p.color = const Color(0xFFFFD54F);
      canvas.drawPath(tri, p);
      p.color = const Color(0xFFD32F2F);
      canvas.drawCircle(const Offset(-0.32, -0.25), 0.2, p);
      canvas.drawCircle(const Offset(0.35, -0.12), 0.2, p);
      canvas.drawCircle(const Offset(0, 0.4), 0.17, p);
      p.color = const Color(0xFF388E3C);
      canvas.drawCircle(const Offset(0.02, -0.3), 0.07, p);
      break;
    case 1: // bun
      p.color = const Color(0xFFD9902F);
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTRB(-1, 0.4, 1, 0.9), const Radius.circular(0.25)), p);
      p.color = const Color(0xFF5D3A1A);
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTRB(-1, 0.12, 1, 0.45), const Radius.circular(0.15)), p);
      p.color = const Color(0xFF7CB342);
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTRB(-1.08, -0.08, 1.08, 0.16), const Radius.circular(0.12)), p);
      p.color = const Color(0xFFE8A33D);
      final bun = Path()
        ..moveTo(-1, 0.1)
        ..cubicTo(-1, -1.3, 1, -1.3, 1, 0.1)
        ..close();
      canvas.drawPath(bun, p);
      p.color = Colors.white70;
      canvas.drawOval(Rect.fromCenter(center: const Offset(-0.4, -0.5), width: 0.18, height: 0.1), p);
      canvas.drawOval(Rect.fromCenter(center: const Offset(0.1, -0.65), width: 0.18, height: 0.1), p);
      canvas.drawOval(Rect.fromCenter(center: const Offset(0.5, -0.4), width: 0.18, height: 0.1), p);
      break;
    case 2: // kheera
      p.color = const Color(0xFF2E7D32);
      canvas.drawCircle(Offset.zero, 0.98, p);
      p.color = const Color(0xFFAED581);
      canvas.drawCircle(Offset.zero, 0.82, p);
      p.color = const Color(0xFFDCEDC8);
      canvas.drawCircle(Offset.zero, 0.6, p);
      p.color = const Color(0xFF9CCC65);
      for (int i = 0; i < 6; i++) {
        final a = i * pi / 3;
        canvas.drawOval(Rect.fromCenter(center: Offset(cos(a) * 0.35, sin(a) * 0.35), width: 0.2, height: 0.12), p);
      }
      break;
    case 3: // onion
      const radii = [0.98, 0.82, 0.66, 0.5, 0.34, 0.18];
      for (int i = 0; i < radii.length; i++) {
        p.color = i.isEven ? const Color(0xFFB05AA8) : const Color(0xFFF6E3F2);
        canvas.drawCircle(Offset.zero, radii[i], p);
      }
      break;
    case 4: // cold drink
      final cup = Path()
        ..moveTo(-0.65, -0.5)
        ..lineTo(0.65, -0.5)
        ..lineTo(0.48, 1.0)
        ..lineTo(-0.48, 1.0)
        ..close();
      p.color = const Color(0xFFE53935);
      canvas.drawPath(cup, p);
      p.color = Colors.white;
      final band = Path()
        ..moveTo(-0.58, 0.05)
        ..lineTo(0.58, 0.05)
        ..lineTo(0.53, 0.45)
        ..lineTo(-0.53, 0.45)
        ..close();
      canvas.drawPath(band, p);
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTRB(-0.75, -0.7, 0.75, -0.46), const Radius.circular(0.1)), p);
      p
        ..color = const Color(0xFFFFEB3B)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.18
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(const Offset(0.1, -0.7), const Offset(0.4, -1.2), p);
      break;
  }
  canvas.restore();
}

void drawPower(Canvas canvas, int type, Offset pos, double pulse) {
  const cols = [Color(0xFFFFB300), Color(0xFFE91E63), Color(0xFF2196F3)];
  final p = Paint();
  p.color = cols[type].withOpacity(0.25);
  canvas.drawCircle(pos, 34 + pulse * 7, p);
  p.color = cols[type];
  canvas.drawCircle(pos, 23, p);
  canvas.save();
  canvas.translate(pos.dx, pos.dy);
  canvas.scale(13);
  p.color = Colors.white;
  if (type == 0) {
    final bolt = Path()
      ..moveTo(0.25, -1)
      ..lineTo(-0.55, 0.1)
      ..lineTo(0, 0.1)
      ..lineTo(-0.25, 1)
      ..lineTo(0.55, -0.2)
      ..lineTo(0, -0.2)
      ..close();
    canvas.drawPath(bolt, p);
  } else if (type == 1) {
    p
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.4;
    final u = Path()
      ..moveTo(-0.55, 0.1)
      ..cubicTo(-0.55, 0.833, 0.55, 0.833, 0.55, 0.1);
    canvas.drawPath(u, p);
    canvas.drawLine(const Offset(-0.55, 0.1), const Offset(-0.55, -0.5), p);
    canvas.drawLine(const Offset(0.55, 0.1), const Offset(0.55, -0.5), p);
    p.color = const Color(0xFF263238);
    canvas.drawLine(const Offset(-0.55, -0.5), const Offset(-0.55, -0.8), p);
    canvas.drawLine(const Offset(0.55, -0.5), const Offset(0.55, -0.8), p);
  } else {
    final sh = Path()
      ..moveTo(0, -1)
      ..lineTo(0.85, -0.65)
      ..cubicTo(0.85, 0.3, 0.4, 0.8, 0, 1)
      ..cubicTo(-0.4, 0.8, -0.85, 0.3, -0.85, -0.65)
      ..close();
    canvas.drawPath(sh, p);
  }
  canvas.restore();
}

// ================================================================ painters
class GamePainter extends CustomPainter {
  final _GamePageState g;
  GamePainter(this.g);

  // name tags are laid out once and reused (laying out text every frame is slow on weak phones)
  static final Map<String, TextPainter> _nameCache = {};
  static TextPainter _nameTp(String name) {
    var tp = _nameCache[name];
    if (tp == null) {
      if (_nameCache.length > 120) _nameCache.clear();
      tp = TextPainter(
        text: TextSpan(text: name, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      _nameCache[name] = tp;
    }
    return tp;
  }

  // draws the visible beads of a big snake: ONE call for the dark outline, then ONE call per colour
  static void _bodyBatched(Canvas canvas, Snake s, double r, double scale, int step, bool boosted, Rect view) {
    final pts = s.body;
    final n = pts.length;
    final all = <Offset>[];
    final groups = <int, List<Offset>>{};
    final colors = <int, Color>{};
    for (int i = n - 1; i > 0; i -= step) {
      final p = pts[i];
      if (!view.contains(p)) continue;
      var col = skinColor(s.skin, s.color, i, n);
      if (boosted) col = Color.lerp(col, Colors.white, 0.25)!;
      final key = col.value & 0xF8F8F8F8; // similar colours share one call
      (groups[key] ??= <Offset>[]).add(p);
      colors.putIfAbsent(key, () => col);
      all.add(p);
    }
    if (all.isEmpty) return;
    final dp = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    if (r * scale > 4.5) {
      dp
        ..strokeWidth = (r + max(1.5, r * 0.12) * 0.5) * 2
        ..color = Color.lerp(s.color, Colors.black, 0.6)!;
      canvas.drawPoints(PointMode.points, all, dp);
    }
    dp.strokeWidth = r * 2;
    groups.forEach((k, list) {
      dp.color = colors[k]!;
      canvas.drawPoints(PointMode.points, list, dp);
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final base = (size.shortestSide / 700).clamp(0.6, 1.6);
    final scale = base * (1 - min(g.player.len, 700) / 700 * 0.45);
    final cam = g.cam;

    final theme = mapThemeOf(worldSize);
    paint.color = mapVoidColor(theme);
    canvas.drawRect(Offset.zero & size, paint);

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    canvas.translate(-cam.dx, -cam.dy);

    final view = Rect.fromCenter(center: cam, width: size.width / scale, height: size.height / scale).inflate(60);
    final world = Rect.fromLTWH(0, 0, worldSize, worldSize);

    paint.color = mapBaseColor(theme);
    canvas.drawRect(world, paint);
    canvas.save();
    canvas.clipRect(world);
    drawMapBackground(canvas, theme, view, DateTime.now().millisecondsSinceEpoch / 1000.0, fine: scale >= 0.5);
    canvas.restore();

    paint
      ..style = PaintingStyle.stroke
      ..color = Colors.redAccent
      ..strokeWidth = 8;
    canvas.drawRect(world, paint);
    paint.style = PaintingStyle.fill;

    // food (plain dots when zoomed out or when very many foods are on screen: much cheaper)
    int visFood = 0;
    for (final f in g.foods) {
      if (view.contains(f.pos)) visFood++;
    }
    final simpleFood = scale < 0.5 || visFood > 150;
    for (final f in g.foods) {
      if (!view.contains(f.pos)) continue;
      if (simpleFood) {
        paint.color = _foodDot[f.type];
        canvas.drawCircle(f.pos, f.r * 1.15, paint);
        continue;
      }
      paint.color = Colors.white.withOpacity(0.10);
      canvas.drawCircle(f.pos, f.r * 1.3, paint);
      drawFood(canvas, f.type, f.pos, f.r);
    }

    // power-ups
    final pulse = sin(DateTime.now().millisecondsSinceEpoch / 250) * 0.5 + 0.5;
    for (final pu in g.powers) {
      if (view.contains(pu.pos)) drawPower(canvas, pu.type, pu.pos, pulse);
    }

    // snakes
    final order = [...g.snakes.where((s) => !s.isPlayer), g.player];
    for (final s in order) {
      if (!s.alive) continue;
      final r = s.radius;
      final n = s.body.length;
      // snakes that are completely out of sight are not drawn at all (uses the real body bounding box)
      final pad = r * 3 + 20;
      if (s.maxX + pad < view.left || s.minX - pad > view.right || s.maxY + pad < view.top || s.minY - pad > view.bottom) continue;
      final nowSec = DateTime.now().millisecondsSinceEpoch / 1000.0;
      // level of detail: long snakes / zoomed-out view draw fewer legs and segments
      final legStep = n > 300 ? 6 : ((n > 100 || scale < 0.4) ? 4 : 2);
      final bodyStep = n > 300 ? 3 : (n > 100 ? 2 : 1);
      final outline = r * scale > 4.5;
      final boosted = s.boosting || s.speedT > 0;
      drawCentipedeLegs(canvas, s.body, r, nowSec,
          view: view, legColor: Color.lerp(s.color, Colors.black, 0.55), step: legStep);
      void seg(int i) {
        final p = s.body[i];
        if (!view.contains(p)) return;
        var col = skinColor(s.skin, s.color, i, n);
        if (boosted) col = Color.lerp(col, Colors.white, 0.25)!;
        paint
          ..style = PaintingStyle.fill
          ..color = col;
        canvas.drawCircle(p, r, paint);
        if (outline) {
          paint
            ..style = PaintingStyle.stroke
            ..strokeWidth = max(1.5, r * 0.12)
            ..color = Color.lerp(col, Colors.black, 0.45)!;
          canvas.drawCircle(p, r, paint);
          paint.style = PaintingStyle.fill;
        }
      }

      if (n > 120) {
        // LAG FIX: big snake = a few draw calls (one per colour) instead of hundreds of single circles
        _bodyBatched(canvas, s, r, scale, bodyStep, boosted, view);
      } else {
        for (int i = n - 1; i > 0; i -= bodyStep) {
          seg(i);
        }
      }
      seg(0);
      final h = s.head;
      final dir = Offset(cos(s.angle), sin(s.angle));
      final perp = Offset(-dir.dy, dir.dx);
      for (final side in [-1, 1]) {
        final e = h + dir * r * 0.4 + perp * r * 0.5 * side.toDouble();
        paint.color = Colors.white;
        canvas.drawCircle(e, r * 0.35, paint);
        paint.color = Colors.black;
        canvas.drawCircle(e + dir * r * 0.12, r * 0.18, paint);
      }
      if (s.shieldT > 0) {
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..color = Colors.lightBlueAccent.withOpacity(s.shieldT < 2 ? 0.4 + pulse * 0.5 : 0.9);
        canvas.drawCircle(h, r * 1.9, paint);
        paint.style = PaintingStyle.fill;
      }
      if (g.showNames && view.contains(h)) {
        final tp = _nameTp(s.name);
        tp.paint(canvas, h + Offset(-tp.width / 2, -r - 24));
      }
    }
    // direction arrow: appears while you touch the screen and fades away when you let go
    final pl = g.player;
    final al = g.arrowAlpha;
    if (g.showArrow && !g.joystick && pl.alive && pl.body.isNotEmpty && al > 0.03) {
      final ang = g.role == NetRole.client ? g.clientTarget : pl.target;
      final dir = Offset(cos(ang), sin(ang));
      final side = Offset(-dir.dy, dir.dx);
      final k = 1 / scale; // keeps the arrow the same size on the screen
      final a0 = pl.head + dir * (pl.radius + 14 * k);
      final a1 = pl.head + dir * (pl.radius + 50 * k);
      final tip = a1 + dir * 13 * k;
      Paint stroke(double w, Color c) => Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = w * k
        ..color = c;
      canvas.drawLine(a0, a1, stroke(10, kLime.withOpacity(0.22 * al))); // soft glow
      canvas.drawLine(a0, a1, stroke(6, Colors.black.withOpacity(0.35 * al))); // dark edge
      canvas.drawLine(a0, a1, stroke(3.4, kLime.withOpacity(0.95 * al)));
      final head = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(a1.dx + side.dx * 8.5 * k, a1.dy + side.dy * 8.5 * k)
        ..lineTo(a1.dx - side.dx * 8.5 * k, a1.dy - side.dy * 8.5 * k)
        ..close();
      canvas.drawPath(head, Paint()..color = Colors.black.withOpacity(0.35 * al));
      canvas.save();
      canvas.translate(-dir.dx * 1.2 * k, -dir.dy * 1.2 * k);
      canvas.drawPath(head, Paint()..color = kLime.withOpacity(0.95 * al));
      canvas.restore();
    }
    canvas.restore();

    // touch steering: a faint ring where the finger started + a dot under the finger
    if (g.touchActive && g.touchAnchor != null && !g.joystick) {
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withOpacity(0.28);
      canvas.drawCircle(g.touchAnchor!, 46, paint);
      paint
        ..style = PaintingStyle.fill
        ..color = Colors.white.withOpacity(0.25);
      canvas.drawCircle(g.touchPos, 18, paint);
    }

    // minimap (right side, just above the BOOST button)
    const mm = 90.0;
    final off = Offset(size.width - mm - 16, size.height - mm - 124);
    paint.color = Colors.black45;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(off.dx, off.dy, mm, mm), const Radius.circular(10)), paint);
    for (final d in g.mmDots()) {
      final p = off + Offset(d.p.dx / worldSize * mm, d.p.dy / worldSize * mm);
      paint.color = d.me ? Colors.white : d.c.withOpacity(0.8);
      canvas.drawCircle(p, d.me ? 4 : 2, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class JoyPainter extends CustomPainter {
  final Offset joy;
  JoyPainter(this.joy);
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final p = Paint()..color = Colors.white.withOpacity(0.12);
    canvas.drawCircle(c, 58, p);
    p
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white30;
    canvas.drawCircle(c, 58, p);
    p
      ..style = PaintingStyle.fill
      ..color = Colors.white.withOpacity(0.45);
    canvas.drawCircle(c + joy, 26, p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ================================================================ home screen painters
const kLime = Color(0xFF7CFF6B);
const _foodDot = [Color(0xFFFFD54F), Color(0xFFD9902F), Color(0xFFAED581), Color(0xFFB05AA8), Color(0xFFE53935)];
const kCyan = Color(0xFF39E1FF);
const kViolet = Color(0xFF8E5BFF);
const kPink = Color(0xFFFF4FA3);

class HomeBgPainter extends CustomPainter {
  final ValueNotifier<double> clock;
  HomeBgPainter(this.clock) : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock.value;
    final w = size.width, h = size.height;
    final rect = Offset.zero & size;

    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0E0A24), Color(0xFF1A0F3D), Color(0xFF081A2B)],
        ).createShader(rect),
    );

    // soft glowing blobs
    const blobs = [
      [0.15, 0.12, 0.55, 0xFF8E5BFF],
      [0.90, 0.35, 0.50, 0xFF39E1FF],
      [0.20, 0.70, 0.55, 0xFFFF4FA3],
      [0.85, 0.92, 0.50, 0xFF7CFF6B],
    ];
    for (int i = 0; i < blobs.length; i++) {
      final b = blobs[i];
      final c = Offset(w * (b[0] + 0.05 * sin(t * 0.3 + i)), h * (b[1] + 0.04 * cos(t * 0.25 + i)));
      final r = w * b[2];
      final col = Color(b[3].toInt());
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(colors: [col.withOpacity(0.28), col.withOpacity(0)]).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }

    // floating food (ONE shared transparency layer instead of one per item: much lighter on slow phones)
    canvas.saveLayer(rect, Paint()..color = Colors.white.withOpacity(0.28));
    for (int i = 0; i < 12; i++) {
      final bx = ((i * 0.137 + 0.06) % 1.0) * w;
      final by = ((i * 0.291 + t * 0.012 * (0.6 + (i % 3) * 0.35)) % 1.0) * h;
      final sz = 12.0 + (i % 4) * 5;
      canvas.save();
      canvas.translate(bx + sin(t * 0.6 + i) * 14, by);
      canvas.rotate(t * 0.4 + i);
      drawFood(canvas, i % foodTypes, Offset.zero, sz);
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class SnakePreviewPainter extends CustomPainter {
  final ValueNotifier<double> clock;
  final int skin;
  final Color color;
  SnakePreviewPainter(this.clock, this.skin, this.color) : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock.value;
    final w = size.width, h = size.height;
    const n = 28;
    final spacing = w * 0.025;
    final r = min(h * 0.2, 17.0);
    final pts = <Offset>[];
    for (int i = 0; i < n; i++) {
      pts.add(Offset(w * 0.78 - i * spacing, h / 2 + sin(i * 0.38 - t * 3.2) * h * 0.17));
    }
    final p = Paint();
    drawCentipedeLegs(canvas, pts, r * 0.8, t, legColor: Color.lerp(color, Colors.black, 0.55));
    for (int i = n - 1; i >= 0; i--) {
      p.color = skinColor(skin, color, i, n);
      final rad = r * (1 - 0.45 * i / n) * (i == 0 ? 1.12 : 1);
      canvas.drawCircle(pts[i], rad, p);
      final fill = p.color;
      p
        ..style = PaintingStyle.stroke
        ..strokeWidth = max(1.2, rad * 0.12)
        ..color = Color.lerp(fill, Colors.black, 0.45)!;
      canvas.drawCircle(pts[i], rad, p);
      p.style = PaintingStyle.fill;
    }
    // eyes
    final head = pts[0];
    var dir = head - pts[2];
    dir = dir / dir.distance;
    final perp = Offset(-dir.dy, dir.dx);
    for (final side in const [-1.0, 1.0]) {
      final e = head + dir * r * 0.45 + perp * r * 0.5 * side;
      p.color = Colors.white;
      canvas.drawCircle(e, r * 0.36, p);
      p.color = Colors.black;
      canvas.drawCircle(e + dir * r * 0.12, r * 0.18, p);
    }
    // a pizza to chase
    drawFood(canvas, 0, Offset(w * 0.92, h / 2 + sin(t * 2.5) * 5), 12);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}


// ================================================================ ADS (Google AdMob)
// App id (AndroidManifest + Info.plist): ca-app-pub-8815870887887674~7058253899
// Revive uses a rewarded interstitial. The player opts in with WATCH AD • REVIVE,
// and the revive reward is granted only after the ad reports the reward.
class AdsManager {
  // ---- YOUR real ad units: used ONLY in release builds (flutter build apk / appbundle) ----
  static const _realBannerId = 'ca-app-pub-8815870887887674/1016423879';
  static const _realInterstitialId = 'ca-app-pub-8815870887887674/9325324587';
  static const _realRewardedInterstitialId = 'ca-app-pub-8815870887887674/6455618661';

  // ---- Google's official TEST ad units: used in debug / profile runs (flutter run) ----
  static const _testBannerId = 'ca-app-pub-3940256099942544/6300978111';
  static const _testInterstitialId = 'ca-app-pub-3940256099942544/1033173712';
  static const _testRewardedInterstitialId = 'ca-app-pub-3940256099942544/5354046379';

  // Testing can never touch your real ads, so your AdMob account stays safe.
  static String get bannerId => kReleaseMode ? _realBannerId : _testBannerId;
  static String get interstitialId => kReleaseMode ? _realInterstitialId : _testInterstitialId;
  static String get rewardedInterstitialId => kReleaseMode ? _realRewardedInterstitialId : _testRewardedInterstitialId;

  // These ad units are the Android placements. iOS needs its own units.
  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static gma.InterstitialAd? _inter;
  static gma.RewardedInterstitialAd? _rewardedInterstitial;
  static int _deaths = 0;
  static int _interToken = 0;
  static bool _interLoading = false;
  static bool _interRetryScheduled = false;
  static bool _fullScreenVisible = false;
  static bool _rewardLoading = false;
  static bool _rewardRetryScheduled = false;
  static DateTime _lastFullScreen = DateTime.fromMillisecondsSinceEpoch(0);
  static const int _minGapSeconds = 60; // minimum time between two full-screen ads
  static bool get _gapOk => DateTime.now().difference(_lastFullScreen).inSeconds >= _minGapSeconds;

  static bool get rewardAvailable => _rewardedInterstitial != null;

  /// becomes true when the ads SDK is ready (the banner waits for it)
  static final ValueNotifier<bool> ready = ValueNotifier(false);
  static bool _initStarted = false;

  static Future<void> init() async {
    if (!supported || _initStarted) return;
    _initStarted = true;
    try {
      await gma.MobileAds.instance.initialize();
      ready.value = true;
      _loadInterstitial();
      loadRewardedInterstitial();
    } catch (_) {}
  }

  static void _loadInterstitial() {
    if (!supported || _inter != null || _interLoading) return;
    _interLoading = true;
    gma.InterstitialAd.load(
      adUnitId: interstitialId,
      request: const gma.AdRequest(),
      adLoadCallback: gma.InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _interLoading = false;
          _interRetryScheduled = false;
          _inter = ad;
        },
        onAdFailedToLoad: (_) {
          _interLoading = false;
          _inter = null;
          if (_interRetryScheduled) return;
          _interRetryScheduled = true;
          Future.delayed(const Duration(seconds: 30), () {
            _interRetryScheduled = false;
            _loadInterstitial();
          });
        },
      ),
    );
  }

  /// Preloads the revive rewarded interstitial so it is ready on game over.
  static void loadRewardedInterstitial() {
    if (!supported || _rewardedInterstitial != null || _rewardLoading) return;
    _rewardLoading = true;
    gma.RewardedInterstitialAd.load(
      adUnitId: rewardedInterstitialId,
      request: const gma.AdRequest(),
      rewardedInterstitialAdLoadCallback: gma.RewardedInterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _rewardLoading = false;
          _rewardRetryScheduled = false;
          _rewardedInterstitial = ad;
        },
        onAdFailedToLoad: (_) {
          _rewardLoading = false;
          _rewardedInterstitial = null;
          if (_rewardRetryScheduled) return;
          _rewardRetryScheduled = true;
          Future.delayed(const Duration(seconds: 30), () {
            _rewardRetryScheduled = false;
            loadRewardedInterstitial();
          });
        },
      ),
    );
  }

  /// Drops a game-over interstitial that has not opened yet.
  /// Called when the player revives, plays again, or leaves, so an ad
  /// does not cover the next run.
  static void cancelPendingInterstitial() {
    _interToken++;
  }

  /// Call when a game ends. After every 3rd game over the interstitial is due;
  /// it is shown only if at least 60 seconds passed since the last full-screen ad.
  static void onGameOver() {
    if (!supported) return;
    _deaths++;
    if (_deaths < 3) return;
    final token = ++_interToken;
    Future.delayed(const Duration(milliseconds: 900), () {
      if (token != _interToken || _fullScreenVisible || !_gapOk) return;
      _showInterstitial();
    });
  }

  static void _showInterstitial() {
    final ad = _inter;
    if (ad == null || _fullScreenVisible) return;
    _inter = null;
    _deaths = 0;
    _fullScreenVisible = true;
    _lastFullScreen = DateTime.now();
    ad.fullScreenContentCallback = gma.FullScreenContentCallback(
      onAdDismissedFullScreenContent: (a) {
        _fullScreenVisible = false;
        _lastFullScreen = DateTime.now();
        a.dispose();
        _loadInterstitial();
      },
      onAdFailedToShowFullScreenContent: (a, _) {
        _fullScreenVisible = false;
        a.dispose();
        _loadInterstitial();
      },
    );
    try {
      ad.show();
    } catch (_) {
      _fullScreenVisible = false;
      ad.dispose();
      _loadInterstitial();
    }
  }

  /// Shows the revive rewarded interstitial. [onReward] runs only if the player earns the reward.
  static void showRewardedInterstitial(void Function() onReward) {
    final ad = _rewardedInterstitial;
    if (ad == null || _fullScreenVisible) return;
    cancelPendingInterstitial();
    _rewardedInterstitial = null;
    _fullScreenVisible = true;
    _lastFullScreen = DateTime.now();
    ad.fullScreenContentCallback = gma.FullScreenContentCallback(
      onAdDismissedFullScreenContent: (a) {
        _fullScreenVisible = false;
        _lastFullScreen = DateTime.now();
        a.dispose();
        loadRewardedInterstitial();
      },
      onAdFailedToShowFullScreenContent: (a, _) {
        _fullScreenVisible = false;
        a.dispose();
        loadRewardedInterstitial();
      },
    );
    try {
      ad.show(onUserEarnedReward: (_, __) => onReward());
    } catch (_) {
      _fullScreenVisible = false;
      ad.dispose();
      loadRewardedInterstitial();
    }
  }

  /// Revive entry point: watch the rewarded interstitial, then continue the run.
  static void showReward(void Function() onReward) => showRewardedInterstitial(onReward);
}

class AdBanner extends StatefulWidget {
  const AdBanner({super.key});
  @override
  State<AdBanner> createState() => _AdBannerState();
}

class _AdBannerState extends State<AdBanner> {
  gma.BannerAd? _ad;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    if (!AdsManager.supported) return;
    if (AdsManager.ready.value) {
      _load();
    } else {
      AdsManager.ready.addListener(_onReady);
    }
  }

  void _onReady() {
    AdsManager.ready.removeListener(_onReady);
    if (mounted) _load();
  }

  void _load() {
    if (_ad != null) return;
    _ad = gma.BannerAd(
      adUnitId: AdsManager.bannerId,
      size: gma.AdSize.banner,
      request: const gma.AdRequest(),
      listener: gma.BannerAdListener(
        onAdLoaded: (_) {
          if (mounted) setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, _) {
          ad.dispose();
          _ad = null;
        },
      ),
    )..load();
  }

  @override
  void dispose() {
    AdsManager.ready.removeListener(_onReady);
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (!_loaded || ad == null) return const SizedBox.shrink();
    return SizedBox(width: 320, height: 50, child: gma.AdWidget(ad: ad));
  }
}


// ================================================================ centipede skin (legs + antennae)
void drawCentipedeLegs(Canvas canvas, List<Offset> pts, double r, double t, {Rect? view, Color? legColor, int step = 2}) {
  if (pts.length < 3) return;
  final p = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = max(2.0, r * 0.22)
    ..color = legColor ?? const Color(0xFF5A2A0B);
  final footColor = Color.lerp(legColor ?? const Color(0xFF5A2A0B), Colors.black, 0.4)!;
  final lines = <Offset>[]; // LAG FIX: collected first, drawn in two calls at the end
  final feet = <Offset>[];
  for (int i = 1; i < pts.length - 1; i += step) {
    final c = pts[i];
    if (view != null && !view.contains(c)) continue;
    var d = pts[i - 1] - pts[i + 1];
    final dl = d.distance;
    if (dl < 0.001) continue;
    d = d / dl;
    final perp = Offset(-d.dy, d.dx);
    final swing = sin(t * 9 + i * 0.7) * r * 0.5;
    for (final side in const [-1.0, 1.0]) {
      final start = c + perp * side * r * 0.5;
      final tip = c + perp * side * r * 1.75 + d * swing * side;
      lines.add(start);
      lines.add(tip);
      feet.add(tip);
    }
  }
  if (lines.isNotEmpty) {
    canvas.drawPoints(PointMode.lines, lines, p);
    final foot = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = p.strokeWidth * 1.4
      ..color = footColor;
    canvas.drawPoints(PointMode.points, feet, foot);
  }
  // antennae
  var hd = pts[0] - pts[2];
  final hl = hd.distance;
  if (hl > 0.001) {
    hd = hd / hl;
    final hp = Offset(-hd.dy, hd.dx);
    for (final side in const [-1.0, 1.0]) {
      canvas.drawLine(pts[0] + hd * r * 0.8 + hp * side * r * 0.3, pts[0] + hd * r * 2.0 + hp * side * r * 0.9, p);
    }
    // pincers
    final fang = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = max(2.5, r * 0.3)
      ..color = p.color;
    for (final side in const [-1.0, 1.0]) {
      canvas.drawLine(pts[0] + hd * r * 0.85 + hp * side * r * 0.45, pts[0] + hd * r * 1.5 + hp * side * r * 0.12, fang);
    }
  }
}


// ================================================================ MAP BACKGROUNDS (drawn with code, no image files)
const mapThemes = ['Jungle', 'Desert', 'Deep Space'];

int mapThemeOf(double ws) => ws <= 3500 ? 0 : (ws <= 5000 ? 1 : 2);

Color mapBaseColor(int t) => const [Color(0xFF1B3A22), Color(0xFFB8894A), Color(0xFF080820)][t];
Color mapVoidColor(int t) => const [Color(0xFF0A1A0F), Color(0xFF2A1E0E), Color(0xFF020208)][t];

// stable pseudo random number (0..1) for a map cell
double hash2(num x, num y, int s) {
  final v = sin(x * 127.1 + y * 311.7 + s * 74.7) * 43758.5453;
  return v - v.floorToDouble();
}

void _cells(Rect v, double cell, void Function(int cx, int cy, Offset o) f) {
  for (int cx = (v.left / cell).floor() - 1; cx <= (v.right / cell).floor(); cx++) {
    for (int cy = (v.top / cell).floor() - 1; cy <= (v.bottom / cell).floor(); cy++) {
      f(cx, cy, Offset((cx + hash2(cx, cy, 90)) * cell, (cy + hash2(cx, cy, 91)) * cell));
    }
  }
}

/// Draws the scenery of a map. [v] is the visible area in world units,
/// [dn] is a density multiplier (1 = normal, bigger = more objects, used for previews).
void drawMapBackground(Canvas canvas, int theme, Rect v, double t, {double dn = 1, bool fine = true}) {
  switch (theme) {
    case 0:
      _bgForest(canvas, v, dn, fine);
      break;
    case 1:
      _bgDesert(canvas, v, dn, fine);
      break;
    default:
      _bgSpace(canvas, v, t, dn, fine);
  }
}

// ---------------------------------------------------------------- JUNGLE
void _bgForest(Canvas canvas, Rect v, double dn, bool fine) {
  final p = Paint();
  final sp = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = 2;

  // soft patches of light and dark grass
  _cells(v, 520, (cx, cy, o) {
    final h = hash2(cx, cy, 1);
    final base = h < 0.5 ? const Color(0xFF3A8A3F) : const Color(0xFF0D2415);
    final r = 220 + h * 220;
    p.color = base.withOpacity(0.16);
    canvas.drawCircle(o, r, p);
    canvas.drawCircle(o, r * 0.65, p);
  });

  // ponds with lily pads
  _cells(v, 900, (cx, cy, o) {
    if (hash2(cx, cy, 30) > 0.28 * dn) return;
    final rx = 90 + hash2(cx, cy, 31) * 80;
    final ry = rx * 0.65;
    p.color = const Color(0xFF6B5B3A);
    canvas.drawOval(Rect.fromCenter(center: o, width: rx * 2 + 22, height: ry * 2 + 22), p);
    p.color = const Color(0xFF1E6F8F);
    canvas.drawOval(Rect.fromCenter(center: o, width: rx * 2, height: ry * 2), p);
    p.color = const Color(0xFF2A8FB0).withOpacity(0.6);
    canvas.drawOval(Rect.fromCenter(center: o + Offset(-rx * 0.1, -ry * 0.1), width: rx * 1.4, height: ry * 1.4), p);
    p.color = const Color(0xFF3FA34D);
    canvas.drawCircle(o + Offset(rx * 0.3, ry * 0.1), 11, p);
    canvas.drawCircle(o + Offset(-rx * 0.35, -ry * 0.2), 9, p);
    canvas.drawCircle(o + Offset(rx * 0.05, -ry * 0.45), 8, p);
  });

  // grass, flowers, bushes, trees
  _cells(v, 140, (cx, cy, o) {
    final c = hash2(cx, cy, 12), d = hash2(cx, cy, 13);
    if (!fine && c >= 0.05 * dn && d >= 0.03 * dn) return; // zoomed out: only bushes and trees matter
    final a = hash2(cx, cy, 10), b = hash2(cx, cy, 11);
    if (fine && a < 0.5 * dn) {
      sp.color = const Color(0xFF4FA44A);
      final s = 0.8 + b * 0.6;
      canvas.drawLine(o, o + Offset(-4 * s, -9 * s), sp);
      canvas.drawLine(o, o + Offset(0, -12 * s), sp);
      canvas.drawLine(o, o + Offset(4 * s, -9 * s), sp);
    }
    if (fine && b < 0.09 * dn) {
      final q = o + Offset(40 * (c - 0.5), 40 * (d - 0.5));
      const cols = [Color(0xFFFF8FB8), Color(0xFFFFFFFF), Color(0xFFFFE066), Color(0xFF9AD0FF)];
      p.color = cols[(c * 4).floor() % 4];
      canvas.drawCircle(q, 4.2, p);
      p.color = const Color(0xFFFFC107);
      canvas.drawCircle(q, 1.8, p);
    }
    if (c < 0.05 * dn) {
      final q = o + Offset(30 * (a - 0.5), 30 * (d - 0.5));
      p.color = const Color(0xFF14532D);
      canvas.drawCircle(q + const Offset(-11, 3), 15, p);
      canvas.drawCircle(q + const Offset(11, 3), 15, p);
      canvas.drawCircle(q + const Offset(0, -8), 17, p);
      p.color = const Color(0xFF2E7D32);
      canvas.drawCircle(q + const Offset(-4, -10), 8, p);
    }
    if (d < 0.03 * dn) {
      final rr = 38 + a * 30;
      p.color = Colors.black.withOpacity(0.25);
      canvas.drawCircle(o + Offset(rr * 0.25, rr * 0.3), rr, p);
      p.color = const Color(0xFF1B5E20);
      canvas.drawCircle(o, rr, p);
      p.color = const Color(0xFF2E8B3E);
      canvas.drawCircle(o + Offset(-rr * 0.08, -rr * 0.1), rr * 0.75, p);
      p.color = const Color(0xFF55B86A).withOpacity(0.55);
      canvas.drawCircle(o + Offset(-rr * 0.28, -rr * 0.3), rr * 0.35, p);
    }
  });
}

// ---------------------------------------------------------------- DESERT
void _bgDesert(Canvas canvas, Rect v, double dn, bool fine) {
  final p = Paint();
  final sp = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;

  // big light and dark dunes
  _cells(v, 600, (cx, cy, o) {
    final h = hash2(cx, cy, 1);
    p.color = (h < 0.5 ? const Color(0xFFE6BE78) : const Color(0xFF8A622E)).withOpacity(0.28);
    canvas.drawOval(Rect.fromCenter(center: o, width: 520 + h * 200, height: 150 + h * 100), p);
  });

  // oasis with palm trees
  _cells(v, 1100, (cx, cy, o) {
    if (hash2(cx, cy, 30) > 0.22 * dn) return;
    final rx = 80 + hash2(cx, cy, 31) * 50;
    p.color = const Color(0xFF8BC34A).withOpacity(0.5);
    canvas.drawOval(Rect.fromCenter(center: o, width: rx * 2 + 40, height: rx * 1.3 + 40), p);
    p.color = const Color(0xFF2AA9C9);
    canvas.drawOval(Rect.fromCenter(center: o, width: rx * 2, height: rx * 1.3), p);
    p.color = const Color(0xFF7FDDF0).withOpacity(0.6);
    canvas.drawOval(Rect.fromCenter(center: o + const Offset(-10, -6), width: rx * 1.2, height: rx * 0.7), p);
    for (int k = 0; k < 3; k++) {
      final ang = hash2(cx, cy, 40 + k) * 6.28;
      final pc = o + Offset(cos(ang) * (rx + 24), sin(ang) * (rx * 0.65 + 24));
      sp
        ..color = const Color(0xFF2E8B3D)
        ..strokeWidth = 7;
      for (int l = 0; l < 7; l++) {
        final la = l * 6.28 / 7;
        canvas.drawLine(pc, pc + Offset(cos(la), sin(la)) * 30, sp);
      }
      p.color = const Color(0xFF6D4C1F);
      canvas.drawCircle(pc, 5, p);
    }
  });

  // ripples, sparkles, rocks, cactus
  _cells(v, 160, (cx, cy, o) {
    final c = hash2(cx, cy, 12), d = hash2(cx, cy, 13);
    if (!fine && c >= 0.05 * dn && d >= 0.03 * dn) return; // zoomed out: only rocks and cactus matter
    final a = hash2(cx, cy, 10), b = hash2(cx, cy, 11);
    if (fine && a < 0.55 * dn) {
      final path = Path()
        ..moveTo(o.dx, o.dy)
        ..quadraticBezierTo(o.dx + 28, o.dy - 8, o.dx + 55, o.dy)
        ..quadraticBezierTo(o.dx + 82, o.dy + 8, o.dx + 110, o.dy);
      sp
        ..color = Colors.black.withOpacity(0.10)
        ..strokeWidth = 2;
      canvas.drawPath(path, sp);
    }
    if (fine && b < 0.25 * dn) {
      p.color = Colors.white.withOpacity(0.5);
      canvas.drawCircle(o + Offset(60 * (c - 0.5), 60 * (d - 0.5)), 1.6, p);
    }
    if (c < 0.05 * dn) {
      final q = o + Offset(20 * (a - 0.5), 20 * (d - 0.5));
      final rr = 14 + b * 10;
      p.color = Colors.black.withOpacity(0.2);
      canvas.drawOval(Rect.fromCenter(center: q + Offset(4, rr * 0.7), width: rr * 2.4, height: rr * 0.8), p);
      p.color = const Color(0xFF7A6248);
      canvas.drawCircle(q, rr, p);
      canvas.drawCircle(q + Offset(rr * 0.9, rr * 0.3), rr * 0.7, p);
      p.color = const Color(0xFF9C8266);
      canvas.drawCircle(q + Offset(-rr * 0.25, -rr * 0.3), rr * 0.45, p);
    }
    if (d < 0.03 * dn) {
      p.color = Colors.black.withOpacity(0.22);
      canvas.drawOval(Rect.fromCenter(center: o + const Offset(0, 28), width: 44, height: 12), p);
      p.color = const Color(0xFF2F7D3A);
      void bar(Rect r) => canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(5)), p);
      bar(Rect.fromCenter(center: o, width: 16, height: 58));
      bar(Rect.fromLTWH(o.dx - 22, o.dy - 4, 16, 7));
      bar(Rect.fromLTWH(o.dx - 22, o.dy - 22, 8, 26));
      bar(Rect.fromLTWH(o.dx + 6, o.dy - 14, 16, 7));
      bar(Rect.fromLTWH(o.dx + 14, o.dy - 32, 8, 26));
      p.color = const Color(0xFF55B864);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: o + const Offset(-3, -2), width: 3, height: 48), const Radius.circular(2)), p);
    }
  });
}

// ---------------------------------------------------------------- DEEP SPACE
void _bgSpace(Canvas canvas, Rect v, double t, double dn, bool fine) {
  final p = Paint();

  // colourful nebula clouds
  const neb = [Color(0xFF7B1FA2), Color(0xFF1976D2), Color(0xFFD81B60), Color(0xFF00ACC1)];
  _cells(v, 700, (cx, cy, o) {
    final h = hash2(cx, cy, 1);
    if (h > 0.65) return;
    final col = neb[(hash2(cx, cy, 2) * 4).floor() % 4];
    final r = 260 + h * 300;
    final layers = fine ? 4 : 2; // zoomed out: 2 layers are enough (half the GPU work)
    for (int k = 0; k < layers; k++) {
      p.color = col.withOpacity(fine ? 0.07 : 0.10);
      canvas.drawCircle(o, r * (1 - k * (fine ? 0.22 : 0.44)), p);
    }
  });

  // twinkling stars
  _cells(v, 110, (cx, cy, o) {
    for (int k = 0; k < (fine ? 2 : 1); k++) {
      final q = Offset((cx + hash2(cx, cy, 50 + k)) * 110, (cy + hash2(cx, cy, 60 + k)) * 110);
      final ph = hash2(cx, cy, 70 + k);
      final tw = min(1.0, max(0.1, 0.45 + 0.5 * sin(t * 2 + ph * 6.28)));
      final kind = hash2(cx, cy, 80 + k);
      final col = kind < 0.6 ? Colors.white : (kind < 0.8 ? const Color(0xFFA8D8FF) : const Color(0xFFFFF3B0));
      p.color = col.withOpacity(tw);
      canvas.drawCircle(q, 0.8 + ph * 1.4, p);
    }
  });

  // planets (some with rings)
  _cells(v, 1100, (cx, cy, o) {
    if (hash2(cx, cy, 30) > 0.4 * dn) return;
    final rr = 70 + hash2(cx, cy, 31) * 70;
    const pcs = [Color(0xFFE57373), Color(0xFF64B5F6), Color(0xFFFFB74D), Color(0xFF81C784), Color(0xFFBA68C8)];
    final col = pcs[(hash2(cx, cy, 32) * 5).floor() % 5];
    p.color = col.withOpacity(0.10);
    canvas.drawCircle(o, rr * 1.35, p);
    p.color = col;
    canvas.drawCircle(o, rr, p);
    p.color = Colors.black.withOpacity(0.28);
    canvas.drawCircle(o + Offset(rr * 0.25, rr * 0.22), rr * 0.62, p);
    p.color = Colors.black.withOpacity(0.16);
    canvas.drawOval(Rect.fromCenter(center: o + Offset(0, rr * 0.28), width: rr * 1.8, height: rr * 0.18), p);
    canvas.drawOval(Rect.fromCenter(center: o + Offset(0, -rr * 0.25), width: rr * 1.8, height: rr * 0.14), p);
    p.color = Colors.white.withOpacity(0.22);
    canvas.drawCircle(o + Offset(-rr * 0.3, -rr * 0.3), rr * 0.3, p);
    if (hash2(cx, cy, 33) < 0.45) {
      p
        ..style = PaintingStyle.stroke
        ..strokeWidth = rr * 0.12
        ..color = Color.lerp(col, Colors.white, 0.4)!.withOpacity(0.75);
      canvas.drawOval(Rect.fromCenter(center: o, width: rr * 2.9, height: rr * 0.8), p);
      p.style = PaintingStyle.fill;
    }
  });

  // asteroids
  _cells(v, 320, (cx, cy, o) {
    if (hash2(cx, cy, 95) > 0.16 * dn) return;
    final rr = 12 + hash2(cx, cy, 96) * 14;
    p.color = const Color(0xFF5C5C70);
    canvas.drawCircle(o, rr, p);
    canvas.drawCircle(o + Offset(rr * 0.8, rr * 0.2), rr * 0.7, p);
    canvas.drawCircle(o + Offset(-rr * 0.6, rr * 0.5), rr * 0.6, p);
    p.color = const Color(0xFF3E3E50);
    canvas.drawCircle(o + Offset(rr * 0.1, -rr * 0.1), rr * 0.25, p);
    canvas.drawCircle(o + Offset(rr * 0.9, rr * 0.3), rr * 0.18, p);
    p.color = Colors.white.withOpacity(0.18);
    canvas.drawCircle(o + Offset(-rr * 0.3, -rr * 0.4), rr * 0.3, p);
  });
}

// small preview of a map (used in the map selection sheet)
class MapPreviewPainter extends CustomPainter {
  final int theme;
  MapPreviewPainter(this.theme);

  @override
  void paint(Canvas canvas, Size size) {
    final box = Offset.zero & size;
    canvas.drawRect(box, Paint()..color = mapBaseColor(theme));
    canvas.save();
    canvas.clipRect(box);
    const k = 0.42;
    canvas.scale(k);
    final off = Offset(600.0 + theme * 500, 400.0);
    canvas.translate(-off.dx, -off.dy);
    drawMapBackground(canvas, theme, Rect.fromLTWH(off.dx, off.dy, size.width / k, size.height / k), 1.0, dn: 5);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}