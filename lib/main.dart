import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

void main() => runApp(const MaterialApp(
  debugShowCheckedModeBanner: false,
  home: GamePage(),
));

const double worldSize = 3000;
const int foodCount = 500;
final Random rnd = Random();

double wrapAngle(double d) {
  while (d > pi) d -= 2 * pi;
  while (d < -pi) d += 2 * pi;
  return d;
}

class Food {
  Offset pos;
  double r;
  Color color;
  Food(this.pos, this.r, this.color);
}

class Snake {
  final bool isPlayer;
  final String name;
  final Color color;
  final List<Offset> body = [];
  double angle = 0, target = 0, len = 12;
  bool boosting = false, alive = true;
  double dropTimer = 0, aiTimer = 0, respawn = 0;

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

class GamePage extends StatefulWidget {
  const GamePage({super.key});
  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> with SingleTickerProviderStateMixin {
  late final Ticker ticker;
  Duration last = Duration.zero;
  final List<Food> foods = [];
  final List<Snake> snakes = [];
  late Snake player;
  Size size = Size.zero;
  Offset pointer = Offset.zero;
  bool hasPointer = false, boostHeld = false, playing = false;
  int best = 0;
  Offset cam = const Offset(worldSize / 2, worldSize / 2);

  static const botNames = ['Viper', 'Noodle', 'Mamba', 'Cobra', 'Slinky', 'Python', 'Rattler', 'Zippy', 'Basilisk', 'Naga', 'Sidewinder', 'Anaconda'];
  static const palette = [Colors.redAccent, Colors.orangeAccent, Colors.yellow, Colors.lightGreenAccent, Colors.cyanAccent, Colors.lightBlueAccent, Colors.purpleAccent, Colors.pinkAccent];

  Offset randomPos([double margin = 300]) =>
      Offset(margin + rnd.nextDouble() * (worldSize - 2 * margin), margin + rnd.nextDouble() * (worldSize - 2 * margin));

  Color randomFoodColor() => HSVColor.fromAHSV(1, rnd.nextDouble() * 360, 0.8, 1).toColor();

  @override
  void initState() {
    super.initState();
    player = Snake(isPlayer: true, name: 'You', color: Colors.greenAccent, start: randomPos());
    player.alive = false;
    snakes.add(player);
    for (int i = 0; i < botNames.length; i++) {
      snakes.add(Snake(isPlayer: false, name: botNames[i], color: palette[i % palette.length], start: randomPos()));
    }
    for (int i = 0; i < foodCount; i++) {
      foods.add(Food(randomPos(30), 3 + rnd.nextDouble() * 3, randomFoodColor()));
    }
    ticker = createTicker(_tick)..start();
  }

  @override
  void dispose() {
    ticker.dispose();
    super.dispose();
  }

  void startGame() {
    player.reset(randomPos(600));
    cam = player.head;
    playing = true;
  }

  void _tick(Duration t) {
    final dt = ((t - last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    last = t;
    _update(dt);
    setState(() {});
  }

  void _kill(Snake s) {
    s.alive = false;
    for (int i = 0; i < s.body.length; i += 2) {
      final p = s.body[i] + Offset(rnd.nextDouble() * 10 - 5, rnd.nextDouble() * 10 - 5);
      foods.add(Food(p, 5 + rnd.nextDouble() * 2, s.color));
    }
    if (s.isPlayer) {
      playing = false;
      best = max(best, s.score);
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
      Food? best;
      double bd = 350;
      for (final f in foods) {
        final d = (f.pos - h).distance;
        if (d < bd) {
          bd = d;
          best = f;
        }
      }
      if (best != null) {
        s.target = atan2(best.pos.dy - h.dy, best.pos.dx - h.dx);
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
          foods.add(Food(s.body.last, 4, s.color));
        }
      }
    }

    // eat food
    for (final s in snakes) {
      if (!s.alive) continue;
      final reach = s.radius + 8;
      for (int i = foods.length - 1; i >= 0; i--) {
        final f = foods[i];
        if ((f.pos - s.head).distance < reach + f.r) {
          s.len += f.r * 0.15;
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
          final limit = s.radius * 0.7 + o.radius * 0.8;
          for (final p in o.body) {
            if ((p - h).distance < limit) {
              dead = true;
              break;
            }
          }
          if (dead) break;
        }
      }
      if (dead) _kill(s);
    }

    while (foods.length < foodCount) {
      foods.add(Food(randomPos(30), 3 + rnd.nextDouble() * 3, randomFoodColor()));
    }

    if (player.alive) cam = cam + (player.head - cam) * min(1.0, dt * 8);
  }

  @override
  Widget build(BuildContext context) {
    final board = (snakes.where((s) => s.alive).toList()..sort((a, b) => b.len.compareTo(a.len))).take(5).toList();
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B16),
      body: Focus(
        autofocus: true,
        onKeyEvent: (_, e) {
          if (e.logicalKey == LogicalKeyboardKey.space) {
            boostHeld = e is! KeyUpEvent;
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: LayoutBuilder(builder: (context, c) {
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
              left: 16,
              top: 16,
              child: Text('Score: ${player.score}   Best: $best',
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
            ),
            Positioned(
              right: 16,
              top: 16,
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                const Text('Leaderboard', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
                for (final s in board)
                  Text('${s.name}  ${s.score}',
                      style: TextStyle(color: s.isPlayer ? Colors.greenAccent : Colors.white, fontSize: 14)),
              ]),
            ),
            if (playing)
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
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.orange.withOpacity(0.8),
                    ),
                    child: const Text('BOOST', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            if (!playing)
              Center(
                child: Container(
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(16)),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(player.score > 0 ? 'Game Over' : 'Slither',
                        style: const TextStyle(color: Colors.greenAccent, fontSize: 36, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    if (player.score > 0)
                      Text('Score: ${player.score}', style: const TextStyle(color: Colors.white, fontSize: 18)),
                    const SizedBox(height: 8),
                    const Text('Move mouse / drag to steer\nHold Space or BOOST button to speed up',
                        textAlign: TextAlign.center, style: TextStyle(color: Colors.white70)),
                    const SizedBox(height: 16),
                    ElevatedButton(onPressed: startGame, child: const Text('PLAY')),
                  ]),
                ),
              ),
          ]);
        }),
      ),
    );
  }
}

class GamePainter extends CustomPainter {
  final _GamePageState g;
  GamePainter(this.g);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final base = (size.shortestSide / 700).clamp(0.6, 1.6);
    final scale = base * (1 - min(g.player.len, 400) / 400 * 0.35);
    final cam = g.cam;

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    canvas.translate(-cam.dx, -cam.dy);

    final view = Rect.fromCenter(center: cam, width: size.width / scale, height: size.height / scale).inflate(60);

    // world
    paint.color = const Color(0xFF15152B);
    canvas.drawRect(const Rect.fromLTWH(0, 0, worldSize, worldSize), paint);

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

    // border
    paint
      ..color = Colors.redAccent
      ..strokeWidth = 8;
    canvas.drawRect(const Rect.fromLTWH(0, 0, worldSize, worldSize), paint);
    paint.style = PaintingStyle.fill;

    // food
    for (final f in g.foods) {
      if (!view.contains(f.pos)) continue;
      paint.color = f.color.withOpacity(0.3);
      canvas.drawCircle(f.pos, f.r * 1.9, paint);
      paint.color = f.color;
      canvas.drawCircle(f.pos, f.r, paint);
    }

    // snakes (draw player last so it's on top)
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
      // eyes
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
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}