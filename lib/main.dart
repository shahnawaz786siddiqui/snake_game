// Slither-style game in Flutter
// Packages needed:  flutter pub add audioplayers shared_preferences
import 'dart:math';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: GamePage()));

// ================================================================ globals
double worldSize = 5000;
int get foodCount => (worldSize * worldSize / 28000).round();
int get powerCount => max(6, (worldSize * worldSize / 2200000).round());
final Random rnd = Random();

// food types: 0 pizza, 1 bun, 2 kheera, 3 onion, 4 cold drink
const foodTypes = 5;
const skinNames = ['Classic', 'Stripes', 'Rainbow', 'Zebra', 'Fire', 'Candy'];

enum Screen { home, play }

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

  static void die() => _play(_b, _die);
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

  Snake({required this.isPlayer, required this.name, required this.color, required Offset start, this.skin = 0}) {
    reset(start);
  }

  Offset get head => body.first;
  double get radius => 9 + min(len, 300) / 30;
  double get spacing => radius * 0.55;
  int get score => ((len - 12) * 10).floor();

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
    final sp = (boosting ? 300.0 : 170.0) * (speedT > 0 ? 1.3 : 1.0);
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
    } catch (_) {}
  }

  // ---------------------------------------------------------------- game flow
  void startGame(int bots) {
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
      _update(dt);
      setState(() {});
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
    } else {
      s.respawn = 3;
    }
  }

  void _ai(Snake s, double dt) {
    s.aiTimer -= dt;
    final h = s.head;
    s.boosting = false;
    if (h.dx < 200 || h.dx > worldSize - 200 || h.dy < 200 || h.dy > worldSize - 200) {
      s.target = atan2(worldSize / 2 - h.dy, worldSize / 2 - h.dx);
      return;
    }
    for (final o in snakes) {
      if (o == s || !o.alive) continue;
      if ((o.head - h).distance > 700) continue;
      for (int i = 0; i < o.body.length; i += 3) {
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
        if (!s.isPlayer) {
          s.respawn -= dt;
          if (s.respawn <= 0) {
            s.reset(randomPos());
            s.skin = rnd.nextInt(skinNames.length);
            s.color = palette[rnd.nextInt(palette.length)];
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

  Widget _pill(String text, List<Color> colors, VoidCallback onTap, {double w = 160, double h = 56, double fs = 20}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: w,
        height: h,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: colors, begin: Alignment.topCenter, end: Alignment.bottomCenter),
          borderRadius: BorderRadius.circular(h / 2),
          border: Border.all(color: Colors.white24, width: 2),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 8, offset: Offset(0, 4))],
        ),
        child: Text(text,
            style: TextStyle(
                color: Colors.white,
                fontSize: fs,
                fontWeight: FontWeight.w900,
                shadows: const [Shadow(color: Colors.black87, blurRadius: 3, offset: Offset(1, 2))])),
      ),
    );
  }

  Widget _stats(String title, int score, int kills) {
    const lab = TextStyle(color: Color(0xFF8FA8FF), fontWeight: FontWeight.bold, fontSize: 14);
    return Column(children: [
      Text(title, style: lab.copyWith(color: Colors.white54)),
      const SizedBox(height: 6),
      Text('Score  $score', style: lab),
      Text('Kills  $kills', style: lab.copyWith(color: const Color(0xFFFF8F8F))),
    ]);
  }

  Widget _iconBtn(IconData icon, Color color, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 56, color: color),
        const SizedBox(height: 4),
        Text(label,
            style: const TextStyle(
                color: Color(0xFF7CFFB0), fontWeight: FontWeight.bold, fontSize: 15, shadows: [Shadow(color: Colors.black54, blurRadius: 3)])),
      ]),
    );
  }

  Widget _home() {
    final title = Transform.rotate(
      angle: -0.12,
      child: Stack(children: [
        Text('slither.io',
            style: TextStyle(
                fontSize: 54,
                fontWeight: FontWeight.w900,
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 9
                  ..color = Colors.black)),
        ShaderMask(
          shaderCallback: (r) => const LinearGradient(
              colors: [Colors.cyanAccent, Colors.lightGreenAccent, Colors.yellow, Colors.orangeAccent, Colors.pinkAccent, Colors.purpleAccent])
              .createShader(r),
          child: const Text('slither.io', style: TextStyle(fontSize: 54, fontWeight: FontWeight.w900, color: Colors.white)),
        ),
      ]),
    );

    return Stack(children: [
      Positioned.fill(child: CustomPaint(painter: SunburstPainter())),
      SafeArea(
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: Column(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                const SizedBox(height: 10),
                SizedBox(
                  width: 320,
                  height: 260,
                  child: Stack(children: [
                    CustomPaint(size: const Size(320, 260), painter: HomeSnakePainter()),
                    Positioned(top: 70, left: 0, right: 0, child: Center(child: title)),
                  ]),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: 260,
                  child: TextField(
                    controller: nameCtrl,
                    maxLength: 15,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: 'Nickname (optional)',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.white12,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  Expanded(child: _stats('Last game', lastScore, lastKills)),
                  _pill('play!', const [Color(0xFF2F8BFF), Color(0xFF0B3C9E)], () => startGame(25), w: 160, h: 80, fs: 28),
                  Expanded(child: _stats('Your best ever', bestScore, bestKills)),
                ]),
                const SizedBox(height: 16),
                _pill('PLAY VS A.I.', const [Color(0xFF8E6BFF), Color(0xFF5030B8)], () => startGame(40), w: 180, h: 56, fs: 18),
                const SizedBox(height: 24),
                Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  _iconBtn(Icons.bug_report_rounded, playerColor, 'Change Slither', _changeSkin),
                  _iconBtn(Icons.settings, const Color(0xFF8E6BFF), 'Settings', _settings),
                  _iconBtn(Icons.public, Colors.lightBlueAccent, 'Choose Map', _chooseMap),
                ]),
                const SizedBox(height: 10),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }

  void _changeSkin() {
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Change Slither'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Color'),
              const SizedBox(height: 8),
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (int i = 0; i < colorChoices.length; i++)
                  GestureDetector(
                    onTap: () {
                      setState(() => colorIdx = i);
                      setD(() {});
                    },
                    child: CircleAvatar(
                      backgroundColor: colorChoices[i],
                      radius: 17,
                      child: colorIdx == i ? const Icon(Icons.check, color: Colors.black, size: 18) : null,
                    ),
                  )
              ]),
              const Divider(height: 24),
              const Text('Skin'),
              for (int k = 0; k < skinNames.length; k++)
                InkWell(
                  onTap: () {
                    setState(() => skin = k);
                    setD(() {});
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      Icon(skin == k ? Icons.radio_button_checked : Icons.radio_button_off, size: 20),
                      const SizedBox(width: 8),
                      SizedBox(width: 70, child: Text(skinNames[k])),
                      for (int i = 0; i < 8; i++)
                        Container(
                          width: 16,
                          height: 16,
                          margin: const EdgeInsets.only(right: 1),
                          decoration: BoxDecoration(color: skinColor(k, playerColor, i, 8), shape: BoxShape.circle),
                        ),
                    ]),
                  ),
                ),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      ),
    ).then((_) => _save());
  }

  void _settings() {
    Widget sw(String t, bool v, void Function(bool) f, StateSetter setD) => SwitchListTile(
        title: Text(t),
        value: v,
        onChanged: (x) {
          setState(() => f(x));
          setD(() {});
        });
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Settings'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              sw('Sound effects', sound, (x) {
                sound = x;
                Sfx.enabled = x;
              }, setD),
              sw('On-screen joystick', joystick, (x) => joystick = x, setD),
              sw('Show snake names', showNames, (x) => showNames = x, setD),
              sw('Show leaderboard', showBoard, (x) => showBoard = x, setD),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      ),
    ).then((_) => _save());
  }

  void _chooseMap() {
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Choose Map'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            for (int i = 0; i < mapSizes.length; i++)
              ListTile(
                title: Text('${mapNames[i]}  (${mapSizes[i].toInt()} x ${mapSizes[i].toInt()})'),
                leading: Icon(mapChoice == i ? Icons.radio_button_checked : Icons.radio_button_off),
                onTap: () {
                  setState(() => mapChoice = i);
                  setD(() {});
                },
              ),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      ),
    ).then((_) => _save());
  }

  void _ptr(PointerEvent e) {
    if (e.kind == PointerDeviceKind.touch) {
      if (!joystick) {
        joystick = true; // touch screen detected -> show joystick
        _save();
      }
      return;
    }
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
    final board = (snakes.where((s) => s.alive).toList()..sort((a, b) => b.len.compareTo(a.len))).take(8).toList();
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
        if (showBoard)
          Positioned(
            right: 16,
            top: 16,
            child: SafeArea(
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                const Text('Leaderboard', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
                for (final s in board)
                  Text('${s.name}  ${s.score}',
                      style: TextStyle(color: s.isPlayer ? Colors.greenAccent : Colors.white, fontSize: 13)),
              ]),
            ),
          ),
        if (player.alive && joystick)
          Positioned(
            left: 16,
            bottom: 16,
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
                Row(mainAxisSize: MainAxisSize.min, children: [
                  ElevatedButton(onPressed: () => startGame(botCount), child: const Text('PLAY AGAIN')),
                  const SizedBox(width: 12),
                  OutlinedButton(onPressed: () => setState(() => screen = Screen.home), child: const Text('HOME')),
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
      canvas.drawArc(const Rect.fromLTRB(-1, -1, 1, 0.1), pi, pi, true, p);
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
    canvas.drawArc(Rect.fromCircle(center: const Offset(0, 0.1), radius: 0.55), 0, pi, false, p);
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
    final scale = base * (1 - min(g.player.len, 400) / 400 * 0.35);
    final cam = g.cam;

    paint.color = const Color(0xFF07070F);
    canvas.drawRect(Offset.zero & size, paint);

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    canvas.translate(-cam.dx, -cam.dy);

    final view = Rect.fromCenter(center: cam, width: size.width / scale, height: size.height / scale).inflate(60);
    final world = Rect.fromLTWH(0, 0, worldSize, worldSize);

    paint.color = const Color(0xFF15152B);
    canvas.drawRect(world, paint);

    paint
      ..color = Colors.white10
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final x0 = max(0, (view.left / 100).floor() * 100).toDouble();
    final x1 = min(worldSize, view.right);
    final y0 = max(0, (view.top / 100).floor() * 100).toDouble();
    final y1 = min(worldSize, view.bottom);
    for (double x = x0; x <= x1; x += 100) {
      canvas.drawLine(Offset(x, y0), Offset(x, y1), paint);
    }
    for (double y = y0; y <= y1; y += 100) {
      canvas.drawLine(Offset(x0, y), Offset(x1, y), paint);
    }
    paint
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
      for (int i = n - 1; i >= 0; i--) {
        final p = s.body[i];
        if (!view.contains(p)) continue;
        paint.color = skinColor(s.skin, s.color, i, n);
        if (s.boosting || s.speedT > 0) paint.color = Color.lerp(paint.color, Colors.white, 0.25)!;
        canvas.drawCircle(p, r, paint);
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

    // minimap (bottom center)
    const mm = 90.0;
    final off = Offset((size.width - mm) / 2, size.height - mm - 16);
    paint.color = Colors.black45;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(off.dx, off.dy, mm, mm), const Radius.circular(10)), paint);
    for (final s in g.snakes) {
      if (!s.alive) continue;
      final p = off + Offset(s.head.dx / worldSize * mm, s.head.dy / worldSize * mm);
      paint.color = s.isPlayer ? Colors.white : s.color.withOpacity(0.8);
      canvas.drawCircle(p, s.isPlayer ? 4 : 2, paint);
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

class SunburstPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bg = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF7DB2FF), Color(0xFF5B5FD8), Color(0xFF3B2AA5)],
      ).createShader(rect);
    canvas.drawRect(rect, bg);

    final c = Offset(size.width / 2, size.height * 0.3);
    final rays = Paint()..color = Colors.white.withOpacity(0.07);
    const n = 24;
    final R = size.longestSide * 1.5;
    for (int i = 0; i < n; i += 2) {
      final a0 = i * 2 * pi / n, a1 = (i + 1) * 2 * pi / n;
      final path = Path()
        ..moveTo(c.dx, c.dy)
        ..lineTo(c.dx + R * cos(a0), c.dy + R * sin(a0))
        ..lineTo(c.dx + R * cos(a1), c.dy + R * sin(a1))
        ..close();
      canvas.drawPath(path, rays);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class HomeSnakePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final p = Paint();
    Offset bez(double t) {
      final u = 1 - t;
      const a = Offset(.28, .08), b = Offset(1.05, 0.0), c = Offset(-.15, .6), d = Offset(.78, .82);
      final o = a * (u * u * u) + b * (3 * u * u * t) + c * (3 * u * t * t) + d * (t * t * t);
      return Offset(o.dx * w, o.dy * h);
    }

    const n = 80;
    for (int i = 0; i <= n; i++) {
      final t = i / n;
      final r = w * (0.03 + 0.125 * t);
      p.color = (i ~/ 6).isEven ? const Color(0xFFFF9A2E) : const Color(0xFFFF8A1A);
      canvas.drawCircle(bez(t), r, p);
    }
    final head = bez(1);
    p.color = const Color(0xFFFFA43D);
    canvas.drawCircle(head, w * 0.16, p);
    for (final dx in [-0.02, 0.095]) {
      final e = head + Offset(w * dx, -h * 0.01);
      p.color = Colors.white;
      canvas.drawCircle(e, w * 0.06, p);
      p.color = Colors.black;
      canvas.drawCircle(e + Offset(w * 0.006, w * 0.006), w * 0.04, p);
      p.color = Colors.white;
      canvas.drawCircle(e + Offset(-w * 0.004, -w * 0.006), w * 0.012, p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}