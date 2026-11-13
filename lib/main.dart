// Slither-style game in Flutter
// Packages needed:  flutter pub add audioplayers shared_preferences
import 'dart:convert';
import 'dart:io' show HttpServer, InternetAddress, InternetAddressType, NetworkInterface, WebSocket, WebSocketTransformer;
import 'dart:math';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' as gma;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AdService.init();
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
double get huntShare => const [0.25, 0.55, 0.85][difficulty]; // fraction of bots that hunt
double get chaseRange => const [800.0, 1600.0, 2600.0][difficulty]; // how far bots spot a player
double get chaseSpeed => const [1.0, 1.05, 1.12][difficulty]; // bot speed while chasing a player
double get boostNear => const [250.0, 420.0, 420.0][difficulty]; // distance where bots boost
bool get farBoost => difficulty == 2; // hard bots also boost from far away
double newAggr() => rnd.nextDouble() < huntShare ? 0.6 + rnd.nextDouble() * 0.4 : rnd.nextDouble() * 0.45;

const int kPort = 4040;

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
    if (now - _lastEat < 90) return;
    _lastEat = now;
    _play(_a, _eat);
  }

  static final FlutterTts _tts = FlutterTts();
  static bool _ttsReady = false;

  // plays a loud "ui maa!" voice after you die
  static Future<void> _voice() async {
    if (!enabled) return;
    try {
      if (!_ttsReady) {
        _ttsReady = true;
        await _tts.setLanguage('hi-IN');
        await _tts.setVolume(1.0);
        await _tts.setPitch(1.5);
        await _tts.setSpeechRate(0.45);
      }
      await _tts.speak('उई माँ!');
    } catch (_) {}
  }

  static void die() {
    _play(_b, _die);
    _voice();
  }
  static void kill() => _play(_c, _kill);
  static void power() => _play(_d, _power);
}

// ================================================================ models
class Food {
  Offset pos;
  double r;
  int type;
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

  Snake({required this.isPlayer, required this.name, required this.color, required Offset start, this.skin = 0}) {
    reset(start);
  }

  Offset get head => body.first;
  double get radius => 10 + min(len, 700) / 20;
  double get spacing => radius * 0.55;
  int get score => ((len - 12) * 10).floor();

  // make the snake longer right away (used for the big starting snakes)
  void grow(double l) {
    len = l;
    final dir = Offset(cos(angle), sin(angle));
    while (body.length < len.floor()) {
      body.add(body.last - dir * spacing);
    }
  }

  void reset(Offset start) {
    alive = true;
    len = 12;
    kills = 0;
    boosting = false;
    speedT = magnetT = shieldT = 0;
    angle = rnd.nextDouble() * 2 * pi;
    target = angle;
    body.clear();
    final dir = Offset(cos(angle), sin(angle));
    for (int i = 0; i < 12; i++) {
      body.add(start - dir * (spacing * i));
    }
  }

  void move(double dt) {
    final diff = wrapAngle(target - angle);
    final maxTurn = 4.2 * dt;
    angle += diff.clamp(-maxTurn, maxTurn);
    final sp = (boosting ? 300.0 : 170.0) * (speedT > 0 ? 1.3 : 1.0) * speedMul;
    body[0] = body[0] + Offset(cos(angle), sin(angle)) * sp * dt;
    final sc = spacing;
    for (int i = 1; i < body.length; i++) {
      final d = body[i - 1] - body[i];
      final dist = d.distance;
      if (dist > sc) body[i] = body[i - 1] - d / dist * sc;
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

class _GamePageState extends State<GamePage> with SingleTickerProviderStateMixin {
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
  bool firstSnap = true, netBusy = false;
  String hostIp = '';
  String? netMsg;
  SharedPreferences? prefs;

  Screen screen = Screen.home;
  final List<Food> foods = [];
  final List<PowerUp> powers = [];
  final List<Snake> snakes = [];
  late Snake player;
  int botCount = 25;
  Size size = Size.zero;
  Offset pointer = Offset.zero;
  bool hasPointer = false, boostHeld = false;
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
  bool showNames = true, showBoard = true, sound = true, joystick = false;
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
    player = Snake(isPlayer: true, name: 'You', color: playerColor, start: const Offset(2500, 2500));
    ticker = createTicker(_tick)..start();
    _load();
  }

  @override
  void dispose() {
    _leaveNet();
    ipCtrl.dispose();
    ticker.dispose();
    gameFocus.dispose();
    nameCtrl.dispose();
    super.dispose();
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
        joystick = p.getBool('joystick') ?? false;
        nameCtrl.text = p.getString('name') ?? '';
        ipCtrl.text = p.getString('lastIp') ?? '';
        difficulty = (p.getInt('difficulty') ?? 1).clamp(0, 2);
        Sfx.enabled = sound;
      });
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
      p.setBool('joystick', joystick);
      p.setString('name', nameCtrl.text.trim());
      p.setString('lastIp', ipCtrl.text.trim());
      p.setInt('difficulty', difficulty);
    } catch (_) {}
  }

  // ---------------------------------------------------------------- game flow
  void startGame(int bots, {bool hosting = false}) {
    if (!hosting) _leaveNet();
    botCount = bots;
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
    // a few BIG snakes at the start only
    const bigNames = ['Titan', 'Leviathan', 'Anaconda King', 'Basilisk', 'Hydra', 'Colossus'];
    const bigSkins = [4, 3, 2, 1, 5, 7];
    final bigCount = min(bots >= 25 ? const [2, 4, 6][difficulty] : const [1, 2, 3][difficulty], bots);
    for (int i = 0; i < bigCount; i++) {
      final big = snakes[1 + i];
      Offset p;
      do {
        p = randomPos();
      } while ((p - player.head).distance < 1200);
      big.reset(p);
      big.name = bigNames[i];
      big.skin = bigSkins[i];
      big.aggr = 1.0;
      big.grow(150.0 + rnd.nextDouble() * 80);
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
    boostHeld = false;
    joyActive = false;
    joy = Offset.zero;
    _save();
    setState(() => screen = Screen.play);
    gameFocus.requestFocus();
  }

  void _tick(Duration t) {
    final dt = ((t - last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    last = t;
    if (screen == Screen.play) {
      if (role == NetRole.client) {
        _clientUpdate(dt);
      } else {
        _update(dt);
        if (role == NetRole.host) _hostBroadcast(dt);
      }
      setState(() {});
    } else {
      homeClock.value = t.inMicroseconds / 1e6;
    }
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
    for (int i = 0; i < s.body.length; i += 2) {
      final p = s.body[i] + Offset(rnd.nextDouble() * 10 - 5, rnd.nextDouble() * 10 - 5);
      foods.add(Food(p, 10 + rnd.nextDouble() * 3, rnd.nextInt(foodTypes)));
    }
    if (s.isPlayer) {
      _recordPlayer();
      Sfx.die();
      AdService.onGameOver();
    } else {
      s.respawn = 3;
    }
  }

  void _ai(Snake s, double dt) {
    s.aiTimer -= dt;
    final h = s.head;
    s.boosting = false;

    // 1) stay inside the map
    if (h.dx < 200 || h.dx > worldSize - 200 || h.dy < 200 || h.dy > worldSize - 200) {
      s.target = atan2(worldSize / 2 - h.dy, worldSize / 2 - h.dx);
      return;
    }

    // 2) hunters pick a prey: nearest snake (real players are preferred)
    Snake? prey;
    s.speedMul = 1.0;
    if (s.aggr > 0.5) {
      double best = 1e9;
      for (final o in snakes) {
        if (o == s || !o.alive) continue;
        final human = o.isPlayer || o.remote;
        if (!human && o.len > s.len * 1.8 + 20) continue; // bots avoid much bigger bots
        final d = (o.head - h).distance;
        // real players are chased from very far away
        final maxRange = human ? (s.len > 100 ? chaseRange * 1.3 : chaseRange) : 700.0;
        if (d > maxRange) continue;
        final score = human ? d * 0.5 : d;
        if (score < best) {
          best = score;
          prey = o;
        }
      }
    }

    // 3) avoid crashing into bodies (the prey's head area is ignored while attacking)
    for (final o in snakes) {
      if (o == s || !o.alive) continue;
      if ((o.head - h).distance > 700) continue;
      for (int i = (o == prey ? 8 : 0); i < o.body.length; i += 3) {
        final p = o.body[i];
        final d = p - h;
        if (d.distance < s.radius + o.radius + 70) {
          final toP = atan2(d.dy, d.dx);
          if (wrapAngle(toP - s.angle).abs() < 1.6) {
            s.target = toP + (wrapAngle(toP - s.angle) >= 0 ? -1.3 : 1.3);
            return;
          }
        }
      }
    }

    // 4) ATTACK: aim in front of the prey's head so it runs into our body
    if (prey != null) {
      final ph = prey.head;
      final dist = (ph - h).distance;
      final pdir = Offset(cos(prey.angle), sin(prey.angle));
      final lead = difficulty == 0 ? 0.0 : (dist * 0.5).clamp(60.0, 260.0); // easy bots just chase the head
      final aim = ph + pdir * lead;
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
      s.boosting = ((dist < boostNear && s.len > 18) || (farBoost && human && dist < 1500 && s.len > 30)) && wrapAngle(a - s.angle).abs() < 0.8;
      return;
    }

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

  void _update(double dt) {
    for (final s in snakes) {
      if (!s.alive) {
        if (s.remote) {
          if (s.respawnReq) {
            s.respawnReq = false;
            s.reset(randomPos(worldSize * 0.2));
          }
        } else if (!s.isPlayer) {
          s.respawn -= dt;
          if (s.respawn <= 0) {
            s.reset(randomPos());
            s.skin = rnd.nextInt(skinNames.length);
            s.color = palette[rnd.nextInt(palette.length)];
            s.aggr = newAggr();
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
        } else if (hasPointer && size != Size.zero) {
          s.target = atan2(pointer.dy - size.height / 2, pointer.dx - size.width / 2);
        }
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
        s.len -= 5 * dt;
        s.dropTimer += dt;
        if (s.dropTimer > 0.3) {
          s.dropTimer = 0;
          foods.add(Food(s.body.last, 8, rnd.nextInt(foodTypes)));
        }
      }
    }

    // eat food (with magnet pull)
    for (final s in snakes) {
      if (!s.alive) continue;
      final reach = s.radius + 8;
      for (int i = foods.length - 1; i >= 0; i--) {
        final f = foods[i];
        final d = s.head - f.pos;
        var dist = d.distance;
        if (s.magnetT > 0 && dist < 260 && dist > 1) {
          f.pos += d / dist * min(dist, 650 * dt);
          dist = (s.head - f.pos).distance;
        }
        if (dist < reach + f.r * 0.5) {
          s.len += f.r * 0.07;
          foods.removeAt(i);
          if (s.isPlayer) Sfx.eat();
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

    // collisions
    for (final s in snakes) {
      if (!s.alive) continue;
      final h = s.head;
      bool dead = h.dx < 0 || h.dx > worldSize || h.dy < 0 || h.dy > worldSize;
      if (!dead && s.shieldT <= 0) {
        for (final o in snakes) {
          if (o == s || !o.alive) continue;
          if ((o.head - h).distance > o.body.length * o.spacing + 100) continue;
          final limit = s.radius * 0.7 + o.radius * 0.8;
          for (final p in o.body) {
            if ((p - h).distance < limit) {
              dead = true;
              o.kills++;
              if (o.isPlayer) Sfx.kill();
              break;
            }
          }
          if (dead) break;
        }
      }
      if (dead) _kill(s);
    }

    while (foods.length < foodCount) {
      foods.add(newFood());
    }
    while (powers.length < powerCount) {
      powers.add(PowerUp(randomPos(100), rnd.nextInt(3)));
    }

    if (player.alive) cam = cam + (player.head - cam) * min(1.0, dt * 8);
  }

  // ================================================================ UI
  @override
  Widget build(BuildContext context) {
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
      Positioned.fill(child: CustomPaint(painter: HomeBgPainter(homeClock))),
      SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
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
                              Positioned.fill(child: CustomPaint(painter: SnakePreviewPainter(homeClock, skin, playerColor))),
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
        _sw('Sound effects', Icons.volume_up, sound, (x) {
          sound = x;
          Sfx.enabled = x;
        }, setD),
        _sw('Joystick  (off = touch & drag screen)', Icons.gamepad, joystick, (x) => joystick = x, setD),
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
          AdService.onGameOver();
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
    if (!mounted || role == NetRole.client) return;
    setState(() {
      player.reset(randomPos(worldSize * 0.2));
      player.len = 40; // reward: start longer
      player.shieldT = 5; // reward: 5 seconds of shield
      cam = player.head;
    });
  }

  void _playAgain() {
    if (role == NetRole.client) {
      try {
        clientWs?.add(jsonEncode({'t': 'respawn'}));
      } catch (_) {}
    } else if (role == NetRole.host) {
      player.reset(randomPos(worldSize * 0.2));
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

  void _ptr(PointerEvent e) {
    // joystick ON  -> touches on the screen are ignored (steer with the joystick)
    // joystick OFF -> touch / drag anywhere and the centipede follows your finger
    if (e.kind == PointerDeviceKind.touch && joystick) return;
    pointer = e.localPosition;
    hasPointer = true;
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
    final List<List<dynamic>> board = role == NetRole.client
        ? netBoard
        : (snakes.where((s) => s.alive).toList()..sort((a, b) => b.len.compareTo(a.len)))
        .take(8)
        .map<List<dynamic>>((s) => [s.name, s.score, s.isPlayer])
        .toList();
    return LayoutBuilder(builder: (context, c) {
      size = Size(c.maxWidth, c.maxHeight);
      return Stack(children: [
        Positioned.fill(
          child: MouseRegion(
            onHover: (e) {
              pointer = e.localPosition;
              hasPointer = true;
            },
            child: Listener(
              onPointerDown: _ptr,
              onPointerMove: _ptr,
              child: CustomPaint(painter: GamePainter(this)),
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
                if (AdService.supported && role != NetRole.client && AdService.rewardAvailable) ...[
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.amber, foregroundColor: Colors.black),
                    onPressed: () => AdService.showReward(_revive),
                    icon: const Icon(Icons.ondemand_video),
                    label: const Text('WATCH AD  •  REVIVE'),
                  ),
                  const SizedBox(height: 10),
                ],
                Row(mainAxisSize: MainAxisSize.min, children: [
                  ElevatedButton(onPressed: _playAgain, child: const Text('PLAY AGAIN')),
                  const SizedBox(width: 12),
                  OutlinedButton(
                      onPressed: () {
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
    drawMapBackground(canvas, theme, view, DateTime.now().millisecondsSinceEpoch / 1000.0);
    canvas.restore();

    paint
      ..style = PaintingStyle.stroke
      ..color = Colors.redAccent
      ..strokeWidth = 8;
    canvas.drawRect(world, paint);
    paint.style = PaintingStyle.fill;

    // food
    for (final f in g.foods) {
      if (!view.contains(f.pos)) continue;
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
      drawCentipedeLegs(canvas, s.body, r, DateTime.now().millisecondsSinceEpoch / 1000.0,
          view: view, legColor: Color.lerp(s.color, Colors.black, 0.55));
      for (int i = n - 1; i >= 0; i--) {
        final p = s.body[i];
        if (!view.contains(p)) continue;
        paint.color = skinColor(s.skin, s.color, i, n);
        if (s.boosting || s.speedT > 0) paint.color = Color.lerp(paint.color, Colors.white, 0.25)!;
        canvas.drawCircle(p, r, paint);
        final fill = paint.color;
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = max(1.5, r * 0.12)
          ..color = Color.lerp(fill, Colors.black, 0.45)!;
        canvas.drawCircle(p, r, paint);
        paint.style = PaintingStyle.fill;
      }
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
        final tp = TextPainter(
          text: TextSpan(text: s.name, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, h + Offset(-tp.width / 2, -r - 24));
      }
    }
    canvas.restore();

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

    // floating food
    for (int i = 0; i < 16; i++) {
      final bx = ((i * 0.137 + 0.06) % 1.0) * w;
      final by = ((i * 0.291 + t * 0.012 * (0.6 + (i % 3) * 0.35)) % 1.0) * h;
      final sz = 12.0 + (i % 4) * 5;
      canvas.saveLayer(null, Paint()..color = Colors.white.withOpacity(0.28));
      canvas.save();
      canvas.translate(bx + sin(t * 0.6 + i) * 14, by);
      canvas.rotate(t * 0.4 + i);
      drawFood(canvas, i % foodTypes, Offset.zero, sz);
      canvas.restore();
      canvas.restore();
    }
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
    for (final side in [-1.0, 1.0]) {
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
// These are Google's TEST ad ids. Replace them with YOUR AdMob ad unit ids before publishing.
class AdService {
  static const bannerId = 'ca-app-pub-3940256099942544/6300978111';
  static const interstitialId = 'ca-app-pub-3940256099942544/1033173712';
  static const rewardedId = 'ca-app-pub-3940256099942544/5224354917';

  // ads are enabled on Android only (iOS needs its own ids)
  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static gma.InterstitialAd? _inter;
  static gma.RewardedAd? _reward;
  static int _deaths = 0;

  static bool get rewardAvailable => _reward != null;

  static Future<void> init() async {
    if (!supported) return;
    try {
      await gma.MobileAds.instance.initialize();
      _loadInterstitial();
      _loadRewarded();
    } catch (_) {}
  }

  static void _loadInterstitial() {
    gma.InterstitialAd.load(
      adUnitId: interstitialId,
      request: const gma.AdRequest(),
      adLoadCallback: gma.InterstitialAdLoadCallback(
        onAdLoaded: (ad) => _inter = ad,
        onAdFailedToLoad: (_) => _inter = null,
      ),
    );
  }

  static void _loadRewarded() {
    gma.RewardedAd.load(
      adUnitId: rewardedId,
      request: const gma.AdRequest(),
      rewardedAdLoadCallback: gma.RewardedAdLoadCallback(
        onAdLoaded: (ad) => _reward = ad,
        onAdFailedToLoad: (_) => _reward = null,
      ),
    );
  }

  /// Call when a game ends. Shows a full-screen ad on every 3rd game over.
  static void onGameOver() {
    if (!supported) return;
    _deaths++;
    if (_deaths % 3 != 0) return;
    Future.delayed(const Duration(milliseconds: 1200), () {
      final ad = _inter;
      if (ad == null) return;
      _inter = null;
      ad.fullScreenContentCallback = gma.FullScreenContentCallback(
        onAdDismissedFullScreenContent: (a) {
          a.dispose();
          _loadInterstitial();
        },
        onAdFailedToShowFullScreenContent: (a, _) {
          a.dispose();
          _loadInterstitial();
        },
      );
      ad.show();
    });
  }

  /// Shows a rewarded video; [onReward] runs only if the player watched it.
  static void showReward(void Function() onReward) {
    final ad = _reward;
    if (ad == null) return;
    _reward = null;
    ad.fullScreenContentCallback = gma.FullScreenContentCallback(
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        _loadRewarded();
      },
      onAdFailedToShowFullScreenContent: (a, _) {
        a.dispose();
        _loadRewarded();
      },
    );
    ad.show(onUserEarnedReward: (view, reward) => onReward());
  }
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
    if (!AdService.supported) return;
    _ad = gma.BannerAd(
      adUnitId: AdService.bannerId,
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
void drawCentipedeLegs(Canvas canvas, List<Offset> pts, double r, double t, {Rect? view, Color? legColor}) {
  if (pts.length < 3) return;
  final p = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = max(2.0, r * 0.22)
    ..color = legColor ?? const Color(0xFF5A2A0B);
  final foot = Paint()..color = Color.lerp(legColor ?? const Color(0xFF5A2A0B), Colors.black, 0.4)!;
  for (int i = 1; i < pts.length - 1; i += 2) {
    final c = pts[i];
    if (view != null && !view.contains(c)) continue;
    var d = pts[i - 1] - pts[i + 1];
    final dl = d.distance;
    if (dl < 0.001) continue;
    d = d / dl;
    final perp = Offset(-d.dy, d.dx);
    final swing = sin(t * 9 + i * 0.7) * r * 0.5;
    for (final side in [-1.0, 1.0]) {
      final start = c + perp * side * r * 0.5;
      final tip = c + perp * side * r * 1.75 + d * swing * side;
      canvas.drawLine(start, tip, p);
      canvas.drawCircle(tip, p.strokeWidth * 0.7, foot);
    }
  }
  // antennae
  var hd = pts[0] - pts[2];
  final hl = hd.distance;
  if (hl > 0.001) {
    hd = hd / hl;
    final hp = Offset(-hd.dy, hd.dx);
    for (final side in [-1.0, 1.0]) {
      canvas.drawLine(pts[0] + hd * r * 0.8 + hp * side * r * 0.3, pts[0] + hd * r * 2.0 + hp * side * r * 0.9, p);
    }
    // pincers
    final fang = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = max(2.5, r * 0.3)
      ..color = p.color;
    for (final side in [-1.0, 1.0]) {
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
void drawMapBackground(Canvas canvas, int theme, Rect v, double t, {double dn = 1}) {
  switch (theme) {
    case 0:
      _bgForest(canvas, v, dn);
      break;
    case 1:
      _bgDesert(canvas, v, dn);
      break;
    default:
      _bgSpace(canvas, v, t, dn);
  }
}

// ---------------------------------------------------------------- JUNGLE
void _bgForest(Canvas canvas, Rect v, double dn) {
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
    final a = hash2(cx, cy, 10), b = hash2(cx, cy, 11), c = hash2(cx, cy, 12), d = hash2(cx, cy, 13);
    if (a < 0.5 * dn) {
      sp.color = const Color(0xFF4FA44A);
      final s = 0.8 + b * 0.6;
      canvas.drawLine(o, o + Offset(-4 * s, -9 * s), sp);
      canvas.drawLine(o, o + Offset(0, -12 * s), sp);
      canvas.drawLine(o, o + Offset(4 * s, -9 * s), sp);
    }
    if (b < 0.09 * dn) {
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
void _bgDesert(Canvas canvas, Rect v, double dn) {
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
    final a = hash2(cx, cy, 10), b = hash2(cx, cy, 11), c = hash2(cx, cy, 12), d = hash2(cx, cy, 13);
    if (a < 0.55 * dn) {
      final path = Path()
        ..moveTo(o.dx, o.dy)
        ..quadraticBezierTo(o.dx + 28, o.dy - 8, o.dx + 55, o.dy)
        ..quadraticBezierTo(o.dx + 82, o.dy + 8, o.dx + 110, o.dy);
      sp
        ..color = Colors.black.withOpacity(0.10)
        ..strokeWidth = 2;
      canvas.drawPath(path, sp);
    }
    if (b < 0.25 * dn) {
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
void _bgSpace(Canvas canvas, Rect v, double t, double dn) {
  final p = Paint();

  // colourful nebula clouds
  const neb = [Color(0xFF7B1FA2), Color(0xFF1976D2), Color(0xFFD81B60), Color(0xFF00ACC1)];
  _cells(v, 700, (cx, cy, o) {
    final h = hash2(cx, cy, 1);
    if (h > 0.65) return;
    final col = neb[(hash2(cx, cy, 2) * 4).floor() % 4];
    final r = 260 + h * 300;
    for (int k = 0; k < 4; k++) {
      p.color = col.withOpacity(0.07);
      canvas.drawCircle(o, r * (1 - k * 0.22), p);
    }
  });

  // twinkling stars
  _cells(v, 110, (cx, cy, o) {
    for (int k = 0; k < 2; k++) {
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