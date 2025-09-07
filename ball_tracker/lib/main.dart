import 'dart:async';
import 'dart:convert';
import 'dart:io'; // Required for file operations
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart'; // Required for file path
import 'package:share_plus/share_plus.dart'; // Required for sharing
import 'package:shared_preferences/shared_preferences.dart';

// Data model for storing the result of each level attempt
class LevelResult {
  final int level;
  final double time; // Time in seconds
  final bool wasCompleted; // True if success, false if space bar was pressed

  LevelResult({
    required this.level,
    required this.time,
    required this.wasCompleted,
  });

  // Methods to convert the object to and from a Map for JSON serialization
  Map<String, dynamic> toJson() => {
    'level': level,
    'time': time,
    'wasCompleted': wasCompleted,
  };

  factory LevelResult.fromJson(Map<String, dynamic> json) {
    return LevelResult(
      level: json['level'],
      time: json['time'],
      wasCompleted: json['wasCompleted'],
    );
  }
}

void main() {
  runApp(const BallTrackerApp());
}

class BallTrackerApp extends StatelessWidget {
  const BallTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ball Tracking Game',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFFF0F2F5),
        fontFamily: 'Roboto',
      ),
      home: const GameScreen(),
    );
  }
}

// Represents a single ball on the canvas
class Ball {
  Offset position;
  Offset velocity;
  final double radius;
  Color color;
  final Color originalColor;
  bool isTarget;

  Ball({
    required this.position,
    required this.velocity,
    required this.color,
    this.radius = 15.0,
    this.isTarget = false,
  }) : originalColor = color;

  void draw(Canvas canvas) {
    final paint = Paint()..color = color;
    canvas.drawCircle(position, radius, paint);
  }

  void update(Size bounds) {
    if (position.dx + radius >= bounds.width || position.dx - radius <= 0) {
      velocity = Offset(-velocity.dx, velocity.dy);
    }
    if (position.dy + radius >= bounds.height || position.dy - radius <= 0) {
      velocity = Offset(velocity.dx, -velocity.dy);
    }
    position += velocity;
  }
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  int? _userId;
  final TextEditingController _userIdController = TextEditingController();
  List<LevelResult> _userHistory = [];

  List<Ball> balls = [];
  bool isAnimating = false;
  bool isAwaitingClick = false;
  bool isButtonDisabled = false;
  String buttonText = "Start Level";
  String instructions = "Click 'Start' to begin. Watch the yellow balls.";

  final Size gameCanvasSize = const Size(350, 450);

  int level = 1;
  int totalBalls = 3;
  int ballsToTrack = 1;
  double speed = 2.0;
  int foundTargets = 0;
  int _personalBest = 1;

  final Stopwatch _trackingStopwatch = Stopwatch();
  final Stopwatch _reactionStopwatch = Stopwatch();
  Duration? _trackedDuration;

  static const Color targetColor = Color(0xFFFFC107);
  static const Color defaultColor = Color(0xFF007BFF);
  static const Color correctColor = Color(0xFF28A745);
  static const Color incorrectColor = Color(0xFFDC3545);

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 1))
          ..addListener(() {
            if (isAnimating) {
              setState(() {
                for (var ball in balls) {
                  ball.update(gameCanvasSize);
                }
              });
            }
          });

    WidgetsBinding.instance.addPostFrameCallback((_) => _promptForUserId());
  }

  Future<void> _promptForUserId() async {
    String? errorMessage;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('Enter Your User ID'),
              content: TextField(
                controller: _userIdController,
                decoration: InputDecoration(
                  hintText: "e.g., 12345",
                  errorText: errorMessage,
                ),
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
                onChanged: (_) {
                  if (errorMessage != null) {
                    setStateDialog(() {
                      errorMessage = null;
                    });
                  }
                },
              ),
              actions: <Widget>[
                TextButton(
                  child: const Text('Submit'),
                  onPressed: () async {
                    final text = _userIdController.text;
                    if (text.isEmpty) return;

                    final id = int.parse(text);
                    final prefs = await SharedPreferences.getInstance();

                    if (prefs.containsKey('personalBest_$id')) {
                      setStateDialog(() {
                        errorMessage = 'ID "$id" is already taken.';
                      });
                    } else {
                      setState(() {
                        _userId = id;
                      });
                      _loadUserData();
                      Navigator.of(context).pop();
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _loadUserData() async {
    if (_userId == null) return;
    final prefs = await SharedPreferences.getInstance();

    setState(() {
      _personalBest = prefs.getInt('personalBest_$_userId') ?? 1;
    });

    final historyString = prefs.getString('history_$_userId');
    if (historyString != null) {
      final List<dynamic> decodedList = jsonDecode(historyString);
      setState(() {
        _userHistory = decodedList
            .map((item) => LevelResult.fromJson(item))
            .toList();
      });
    }
  }

  Future<void> _saveUserHistory() async {
    if (_userId == null) return;
    final prefs = await SharedPreferences.getInstance();
    final String encodedData = jsonEncode(
      _userHistory.map((item) => item.toJson()).toList(),
    );
    await prefs.setString('history_$_userId', encodedData);
  }

  Future<void> _savePersonalBest() async {
    if (_userId == null) return;
    if (level > _personalBest) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('personalBest_$_userId', level);
      setState(() {
        _personalBest = level;
      });
    }
  }

  // CHANGE: New method to handle exporting data to CSV
  Future<void> _exportHistoryToCsv() async {
    if (_userHistory.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("No history to export.")));
      return;
    }

    // Create CSV content
    final List<String> rowHeader = ['Level', 'Result', 'Time (s)'];
    List<List<String>> rows = [];
    rows.add(rowHeader);

    for (final result in _userHistory) {
      final List<String> row = [
        result.level.toString(),
        result.wasCompleted ? 'Answered' : 'Gave Up',
        result.time.toStringAsFixed(2),
      ];
      rows.add(row);
    }

    String csvData = rows.map((row) => row.join(',')).join('\n');

    // Save the file to a temporary directory
    final directory = await getTemporaryDirectory();
    final path = '${directory.path}/tracking_history_$_userId.csv';
    final file = File(path);
    await file.writeAsString(csvData);

    // Share the file
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("CSV file created. Opening share dialog...")),
    );

    await Share.shareXFiles([
      XFile(path),
    ], subject: 'Ball Tracking History for User $_userId');
  }

  void _setupLevel() {
    setState(() {
      instructions = "Watch the ${ballsToTrack} yellow ball(s).";
      isButtonDisabled = true;
      isAwaitingClick = false;
      isAnimating = false;
      foundTargets = 0;
      _trackedDuration = null;
      _reactionStopwatch.reset();
      balls.clear();

      final random = Random();
      for (int i = 0; i < totalBalls; i++) {
        const radius = 15.0;
        final x =
            radius + random.nextDouble() * (gameCanvasSize.width - 2 * radius);
        final y =
            radius + random.nextDouble() * (gameCanvasSize.height - 2 * radius);
        final angle = random.nextDouble() * 2 * pi;
        final dx = cos(angle) * speed;
        final dy = sin(angle) * speed;
        final isTarget = i < ballsToTrack;
        final color = isTarget ? targetColor : defaultColor;

        balls.add(
          Ball(
            position: Offset(x, y),
            velocity: Offset(dx, dy),
            color: color,
            isTarget: isTarget,
          ),
        );
      }
    });

    Future.delayed(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      setState(() {
        for (var ball in balls) {
          ball.color = defaultColor;
        }
        instructions = 'Tracking... (Press SPACE if you lose track)';
      });
      _startAnimation();
    });
  }

  void _startAnimation() {
    isAnimating = true;
    _trackingStopwatch.reset();
    _trackingStopwatch.start();
    _controller.repeat();

    Future.delayed(const Duration(seconds: 6), () {
      if (!isAnimating || !mounted) return;
      _trackingStopwatch.stop();
      isAnimating = false;
      _controller.stop();

      _reactionStopwatch.reset();
      _reactionStopwatch.start();

      setState(() {
        isAwaitingClick = true;
        instructions =
            "Click the ${ballsToTrack - foundTargets} ball(s) you were tracking.";
      });
    });
  }

  void _handleTap(Offset tapPosition) {
    if (!isAwaitingClick) return;
    for (final ball in balls) {
      final distance = (tapPosition - ball.position).distance;
      if (distance < ball.radius) {
        if (ball.color == correctColor || ball.color == incorrectColor)
          continue;
        setState(() {
          if (ball.isTarget) {
            ball.color = correctColor;
            foundTargets++;
            if (foundTargets == ballsToTrack) {
              _reactionStopwatch.stop();
              double reactionTimeInSeconds =
                  _reactionStopwatch.elapsedMilliseconds / 1000.0;

              instructions = "Correct! Well done! 🎉";
              isAwaitingClick = false;
              isButtonDisabled = false;
              buttonText = "Next Level";

              final result = LevelResult(
                level: level,
                time: reactionTimeInSeconds,
                wasCompleted: true,
              );
              _userHistory.add(result);
              _saveUserHistory();
              _increaseDifficulty();
            } else {
              instructions =
                  "Good job! Find the remaining ${ballsToTrack - foundTargets} ball(s).";
            }
          } else {
            ball.color = incorrectColor;
            instructions = "Incorrect. Try this level again. 🤔";
            isAwaitingClick = false;
            _reactionStopwatch.stop();
            _revealTargets();
            _resetLevel();
          }
        });
        break;
      }
    }
  }

  void _handleSpaceBarPress() {
    if (!isAnimating) return;
    _trackingStopwatch.stop();
    _controller.stop();
    isAnimating = false;
    isAwaitingClick = false;

    setState(() {
      _trackedDuration = _trackingStopwatch.elapsed;
      double timeInSeconds = _trackedDuration!.inMilliseconds / 1000.0;

      final result = LevelResult(
        level: level,
        time: timeInSeconds,
        wasCompleted: false,
      );
      _userHistory.add(result);
      _saveUserHistory();

      String formattedTime = timeInSeconds.toStringAsFixed(1);
      instructions = 'Tracked for ${formattedTime}s. Let\'s see the answer.';
      _revealTargets();
      _resetLevel();
    });
  }

  void _increaseDifficulty() {
    level++;
    _savePersonalBest();
    if (level % 2 == 0 && ballsToTrack < 5) {
      ballsToTrack++;
    }
    totalBalls++;
    if (level % 3 == 0) {
      speed += 0.25;
    }
  }

  void _resetLevel() {
    setState(() {
      isButtonDisabled = false;
      buttonText = "Try Again";
    });
  }

  void _revealTargets() {
    setState(() {
      for (final ball in balls) {
        if (ball.isTarget) {
          ball.color = targetColor;
        }
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _userIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_userId == null) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text("Waiting for User ID..."),
            ],
          ),
        ),
      );
    }

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.space) {
          _handleSpaceBarPress();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            child: Container(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Ball Tracking Challenge 🧠 (User: $_userId)',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0056B3),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Level: $level',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        'Personal Best: $_personalBest',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    "Level History",
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  Container(
                    height: 100,
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListView.builder(
                      itemCount: _userHistory.length,
                      itemBuilder: (context, index) {
                        final result =
                            _userHistory[_userHistory.length - 1 - index];
                        final String resultText = result.wasCompleted
                            ? "Answered in ${result.time.toStringAsFixed(1)}s"
                            : "Gave up at ${result.time.toStringAsFixed(1)}s";

                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8.0,
                            vertical: 2.0,
                          ),
                          child: Text(
                            'Level ${result.level}: $resultText',
                            style: TextStyle(
                              color: result.wasCompleted
                                  ? Colors.green.shade700
                                  : Colors.red.shade700,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: Text(
                      instructions,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color:
                            instructions.contains("Incorrect") ||
                                instructions.contains("Tracked for")
                            ? Colors.red
                            : const Color.fromARGB(255, 34, 34, 34),
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTapDown: (details) => _handleTap(details.localPosition),
                    child: Container(
                      width: gameCanvasSize.width,
                      height: gameCanvasSize.height,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Colors.grey.shade300,
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(8.0),
                        color: const Color(0xFFF8F9FA),
                      ),
                      child: CustomPaint(
                        painter: BallPainter(balls: balls),
                        size: gameCanvasSize,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // CHANGE: Wrapped buttons in a Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton(
                        onPressed: isButtonDisabled ? null : _setupLevel,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF007BFF),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 25,
                            vertical: 12,
                          ),
                          textStyle: const TextStyle(fontSize: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6.0),
                          ),
                        ),
                        child: Text(buttonText),
                      ),
                      const SizedBox(width: 10),
                      // CHANGE: Added the export button
                      ElevatedButton.icon(
                        icon: const Icon(Icons.download),
                        label: const Text("Export CSV"),
                        onPressed: _exportHistoryToCsv,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.teal,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 25,
                            vertical: 12,
                          ),
                          textStyle: const TextStyle(fontSize: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6.0),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class BallPainter extends CustomPainter {
  final List<Ball> balls;
  BallPainter({required this.balls});

  @override
  void paint(Canvas canvas, Size size) {
    for (var ball in balls) {
      ball.draw(canvas);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
