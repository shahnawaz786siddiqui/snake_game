import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

void main() => runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: GamePage()));

// ---------------------------------------------------------------- globals
double worldSize = 5000;
int get foodCount => (worldSize * worldSize / 28000).round();
final Random rnd = Random();

// food types: 0 pizza, 1 bun/burger, 2 kheera (cucumber), 3 onion, 4 cold drink
// (drawn with code, so no emoji font is needed)
const foodEmoji = ['pizza', 'bun', 'kheera', 'onion', 'colddrink'];

void drawFood(Canvas canvas, int type, Offset pos, double r) {
  canvas.save();
  canvas.translate(pos.dx, pos.dy);
  canvas.scale(r * 1.15);
  final p = Paint()..style = PaintingStyle.fill;
  switch (type) {
    case 0: // pizza slice
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
    case 1: // bun / burger
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
    case 2: // kheera (cucumber slice)
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
    case 3: // onion rings
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

enum Screen { home, play }

double wrapAngle(double d) {
  while (d > pi) d -= 2 * pi;
  while (d < -pi) d += 2 * pi;
  return d;
}

class Food {
  Offset pos;
  double r;
  int type;
  Food(this.pos, this.r, this.type);
}

class Snake {
  final bool isPlayer;
  String name;
  Color color;
  final List<Offset> body = [];
  double angle = 0, target = 0, len = 12;
  bool boosting = false, alive = true;
  double dropTimer = 0, aiTimer = 0, respawn = 0;
  int kills = 0;

  Snake({required this.isPlayer, required this.name, required this.color, required Offset start}) {
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
    final sp = boosting ? 300.0 : 170.0;
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

// ---------------------------------------------------------------- page
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

  Screen screen = Screen.home;
  final List<Food> foods = [];
  final List<Snake> snakes = [];
  late Snake player;
  int botCount = 25;
  Size size = Size.zero;
  Offset pointer = Offset.zero;
  bool hasPointer = false, boostHeld = false;
  Offset cam = const Offset(2500, 2500);

  Color playerColor = Colors.greenAccent;
  bool showNames = true, showBoard = true;
  int mapChoice = 1;
  static const mapSizes = [3500.0, 5000.0, 6500.0];
  static const mapNames = ['Small', 'Big', 'Huge'];

  int lastScore = 0, lastKills = 0, bestScore = 0, bestKills = 0;

  static const botNames = [
    'Viper', 'Noodle', 'Mamba', 'Cobra', 'Slinky', 'Python', 'Rattler', 'Zippy', 'Basilisk', 'Naga',
    'Sidewinder', 'Anaconda', 'Ziggy', 'Wiggles', 'Boa', 'Sneaky', 'Kaa', 'Medusa', 'Jormungandr', 'Sir Hiss'
  ];
  static const palette = [
    Colors.redAccent, Colors.orangeAccent, Colors.yellow, Colors.lightGreenAccent, Colors.cyanAccent,
    Colors.lightBlueAccent, Colors.purpleAccent, Colors.pinkAccent, Colors.tealAccent, Colors.amber
  ];

  Offset randomPos([double margin = 300]) =>
      Offset(margin + rnd.nextDouble() * (worldSize - 2 * margin), margin + rnd.nextDouble() * (worldSize - 2 * margin));

  Food newFood() => Food(randomPos(30), 8 + rnd.nextDouble() * 5, rnd.nextInt(foodEmoji.length));

  @override
  void initState() {
    super.initState();
    player = Snake(isPlayer: true, name: 'You', color: playerColor, start: const Offset(2500, 2500));
    ticker = createTicker(_tick)..start();
  }

  @override
  void dispose() {
    ticker.dispose();
    gameFocus.dispose();
    nameCtrl.dispose();
    super.dispose();
  }

  void startGame(int bots) {
    botCount = bots;
    worldSize = mapSizes[mapChoice];
    final nick = nameCtrl.text.trim();
    snakes.clear();
    player = Snake(
      isPlayer: true,
      name: nick.isEmpty ? 'You' : nick,
      color: playerColor,
      start: randomPos(worldSize * 0.2),
    );
    snakes.add(player);
    for (int i = 0; i < bots; i++) {
      final base = botNames[i % botNames.length];
      final name = i >= botNames.length ? '$base${i ~/ botNames.length + 1}' : base;
      snakes.add(Snake(isPlayer: false, name: name, color: palette[rnd.nextInt(palette.length)], start: randomPos()));
    }
    foods.clear();
    while (foods.length < foodCount) {
      foods.add(newFood());
    }
    cam = player.head;
    hasPointer = false;
    boostHeld = false;
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

  void _kill(Snake s) {
    s.alive = false;
    for (int i = 0; i < s.body.length; i += 2) {
      final p = s.body[i] + Offset(rnd.nextDouble() * 10 - 5, rnd.nextDouble() * 10 - 5);
      foods.add(Food(p, 10 + rnd.nextDouble() * 3, rnd.nextInt(foodEmoji.length)));
    }
    if (s.isPlayer) {
      lastScore = s.score;
      lastKills = s.kills;
      bestScore = max(bestScore, s.score);
      bestKills = max(bestKills, s.kills);
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
          if (s.respawn <= 0) s.reset(randomPos());
        }
        continue;
      }
      if (s.isPlayer) {
        if (hasPointer && size != Size.zero) {
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
          foods.add(Food(s.body.last, 8, rnd.nextInt(foodEmoji.length)));
        }
      }
    }

    // eat food
    for (final s in snakes) {
      if (!s.alive) continue;
      final reach = s.radius + 8;
      for (int i = foods.length - 1; i >= 0; i--) {
        final f = foods[i];
        if ((f.pos - s.head).distance < reach + f.r * 0.5) {
          s.len += f.r * 0.07;
          foods.removeAt(i);
        }
      }
    }

    // collisions
    for (final s in snakes) {
      if (!s.alive) continue;
      final h = s.head;
      bool dead = h.dx < 0 || h.dx > worldSize || h.dy < 0 || h.dy > worldSize;
      if (!dead) {
        for (final o in snakes) {
          if (o == s || !o.alive) continue;
          if ((o.head - h).distance > o.body.length * o.spacing + 100) continue;
          final limit = s.radius * 0.7 + o.radius * 0.8;
          for (final p in o.body) {
            if ((p - h).distance < limit) {
              dead = true;
              o.kills++;
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

    if (player.alive) cam = cam + (player.head - cam) * min(1.0, dt * 8);
  }

  // ---------------------------------------------------------------- UI
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
          content: Wrap(spacing: 12, runSpacing: 12, children: [
            for (final c in [Colors.greenAccent, ...palette])
              GestureDetector(
                onTap: () {
                  setState(() => playerColor = c);
                  setD(() {});
                },
                child: CircleAvatar(
                  backgroundColor: c,
                  radius: 20,
                  child: playerColor == c ? const Icon(Icons.check, color: Colors.black) : null,
                ),
              )
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      ),
    );
  }

  void _settings() {
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Settings'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SwitchListTile(
                title: const Text('Show snake names'),
                value: showNames,
                onChanged: (v) {
                  setState(() => showNames = v);
                  setD(() {});
                }),
            SwitchListTile(
                title: const Text('Show leaderboard'),
                value: showBoard,
                onChanged: (v) {
                  setState(() => showBoard = v);
                  setD(() {});
                }),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      ),
    );
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
    );
  }

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
              onPointerDown: (e) {
                pointer = e.localPosition;
                hasPointer = true;
              },
              onPointerMove: (e) {
                pointer = e.localPosition;
                hasPointer = true;
              },
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
                    if (player.alive) {
                      lastScore = player.score;
                      lastKills = player.kills;
                      bestScore = max(bestScore, player.score);
                      bestKills = max(bestKills, player.kills);
                    }
                    setState(() => screen = Screen.home);
                  }),
              Text('Score: ${player.score}   Kills: ${player.kills}',
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
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

// ---------------------------------------------------------------- painters
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

    // grid
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

    // food (emoji)
    for (final f in g.foods) {
      if (!view.contains(f.pos)) continue;
      paint.color = Colors.white.withOpacity(0.10);
      canvas.drawCircle(f.pos, f.r * 1.3, paint);
      drawFood(canvas, f.type, f.pos, f.r);
    }

    // snakes
    final order = [...g.snakes.where((s) => !s.isPlayer), g.player];
    for (final s in order) {
      if (!s.alive) continue;
      final r = s.radius;
      for (int i = s.body.length - 1; i >= 0; i--) {
        final p = s.body[i];
        if (!view.contains(p)) continue;
        final shade = i % 2 == 0 ? 1.0 : 0.82;
        paint.color = Color.lerp(Colors.black, s.color, shade)!;
        if (s.boosting) paint.color = Color.lerp(paint.color, Colors.white, 0.25)!;
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
      if (g.showNames && view.contains(h)) {
        final tp = TextPainter(
          text: TextSpan(text: s.name, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, h + Offset(-tp.width / 2, -r - 24));
      }
    }
    canvas.restore();

    // minimap
    const mm = 110.0;
    final off = Offset(16, size.height - mm - 16);
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