import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'image_slider.dart';

class AnimeVideoPlayer extends StatefulWidget {
  final String videoUrl;
  final String subtitleUrl;
  const AnimeVideoPlayer({
    super.key,
    required this.videoUrl,
    required this.subtitleUrl,
  });
  @override
  _AnimeVideoPlayerState createState() => _AnimeVideoPlayerState();
}

class Subtitle {
  final Duration start;
  final Duration end;
  final String text;
  Subtitle({required this.start, required this.end, required this.text});
}

Future<List<Subtitle>> loadWebVTT(String url) async {
  final response = await http.get(Uri.parse(url));
  if (response.statusCode != 200) {
    throw Exception("Failed to load subtitles");
  }
  final lines = response.body.split('\n');
  final subtitles = <Subtitle>[];
  String? startTime;
  String? endTime;
  StringBuffer textBuffer = StringBuffer();
  for (final rawLine in lines) {
    final line = rawLine.trim();

    if (line.isEmpty || line == 'WEBVTT' || RegExp(r'^\d+$').hasMatch(line)) {
      continue; // skip header, empty lines, and cue numbers
    }

    if (line.contains('-->')) {
      if (startTime != null && endTime != null && textBuffer.isNotEmpty) {
        subtitles.add(
          Subtitle(
            start: _parseDuration(startTime),
            end: _parseDuration(endTime),
            text: _stripHtmlTags(textBuffer.toString().trim()),
          ),
        );
        textBuffer.clear();
      }

      final parts = line.split('-->');
      startTime = parts[0].trim();
      endTime = parts[1].trim();
    } else {
      textBuffer.writeln(line);
    }
  }
  if (startTime != null && endTime != null && textBuffer.isNotEmpty) {
    subtitles.add(
      Subtitle(
        start: _parseDuration(startTime),
        end: _parseDuration(endTime),
        text: _stripHtmlTags(textBuffer.toString().trim()),
      ),
    );
  }
  return subtitles;
}

String _stripHtmlTags(String input) {
  final tagRegExp = RegExp(r'<[^>]*>', multiLine: true, caseSensitive: false);
  return input.replaceAll(tagRegExp, '');
}

Duration _parseDuration(String timeString) {
  try {
    final cleaned = timeString.trim();
    final parts = cleaned.split(':');
    int hours = 0;
    int minutes = 0;
    int seconds = 0;
    int milliseconds = 0;
    if (parts.length == 3) {
      // Format: HH:MM:SS.mmm
      hours = int.parse(parts[0]);
      minutes = int.parse(parts[1]);
      final secParts = parts[2].split('.');
      seconds = int.parse(secParts[0]);
      if (secParts.length > 1) {
        milliseconds = int.parse(secParts[1].padRight(3, '0'));
      }
    } else if (parts.length == 2) {
      // Format: MM:SS.mmm
      minutes = int.parse(parts[0]);
      final secParts = parts[1].split('.');
      seconds = int.parse(secParts[0]);
      if (secParts.length > 1) {
        milliseconds = int.parse(secParts[1].padRight(3, '0'));
      }
    } else {
      throw FormatException("Invalid time format: $timeString");
    }
    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: milliseconds,
    );
  } catch (e) {
    print('⛔ Error parsing timeString "$timeString": $e');
    return Duration.zero;
  }
}

Future<List<Map<String, String>>> fetchHlsVariants(String url) async {
  final response = await http.get(Uri.parse(url));
  if (response.statusCode != 200) throw Exception("Failed to load playlist");
  final lines = response.body.split('\n');
  List<Map<String, String>> variants = [];
  for (int i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('#EXT-X-STREAM-INF')) {
      final resolutionMatch = RegExp(
        r'RESOLUTION=(\d+x\d+)',
      ).firstMatch(lines[i]);
      var resolution = resolutionMatch?.group(1) ?? 'Unknown';
      resolution = resolution.split('x')[1];
      final uri = lines[i + 1];

      variants.add({
        'resolution': '${resolution}p',
        'url': Uri.parse(url).resolve(uri).toString(), // resolve relative URLs
      });
    }
  }
  return variants;
}

class _AnimeVideoPlayerState extends State<AnimeVideoPlayer> {
  VideoPlayerController? _controller;
  bool _showControls = true;
  Duration _currentPosition = Duration.zero;
  bool _isFullScreen = false;
  bool isSeeking = false;
  Duration _overlayDuration = Duration(milliseconds: 800);
  bool _showLeftOverlay = false;
  bool _showRightOverlay = false;
  Timer? _overlayTimer;
  Timer? _subtitleTimer;
  String? _currentQualityUrl; // null means "Auto"
  String? _masterUrl;
  List<Subtitle> _subtitles = [];
  String _currentSubtitle = '';
  List<Map<String, String>> _qualityVariants = [];
  bool manualPause = false; // <-- manual pause flag
  String? _formatDuration(Duration position) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    final minutes = twoDigits(position.inMinutes.remainder(60));
    final seconds = twoDigits(position.inSeconds.remainder(60));
    return "$minutes:$seconds";
  }

  Future<void> _loadSubtitles() async {
    final subtitles = await loadWebVTT(widget.subtitleUrl);
    setState(() {
      _subtitles = subtitles;
    });
  }

  void _checkSubtitles() {
    final position = _controller?.value.position;
    final activeSubtitle = _subtitles.firstWhere(
      (s) => position! >= s.start && position <= s.end,
      orElse: () =>
          Subtitle(start: Duration.zero, end: Duration.zero, text: ''),
    );
    if (_currentSubtitle != activeSubtitle.text) {
      setState(() {
        _currentSubtitle = activeSubtitle.text;
      });
    }
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          statusBarColor: Color(0xFF121212),
          statusBarIconBrightness: Brightness.light,
        ),
      );
    });

    _initController();
  }

  Future<void> _initController() async {
    try {
      _qualityVariants = await fetchHlsVariants(widget.videoUrl);

      _controller = VideoPlayerController.networkUrl(
        Uri.parse(
          _qualityVariants.last['url']!,
        ), // or first, depending on logic
      );

      await _controller!.initialize();

      _controller!.addListener(() {
        if (!mounted || isSeeking) return;

        final value = _controller!.value;

        setState(() {
          _currentPosition = value.position;
        });

        if (value.position >= value.duration && !manualPause) {
          setState(() {
            manualPause = true;
          });
        }
      });

      setState(() {
        _masterUrl = _controller!.dataSource;
        _currentQualityUrl = _masterUrl;
        manualPause = false;
      });

      _controller!.play();
      _toggleFullScreen();

      if (widget.subtitleUrl.isNotEmpty) {
        _subtitleTimer = Timer.periodic(Duration(milliseconds: 500), (_) {
          if (_controller!.value.isPlaying) {
            _checkSubtitles();
          }
        });

        _loadSubtitles();
      }
    } catch (e) {
      debugPrint('Error fetching quality variants: $e');
      _qualityVariants = [];
    }
  }

  void _switchQuality(String newUrl) async {
    final oldPosition = _controller!.value.position;
    final wasPlaying = _controller!.value.isPlaying;

    await _controller!.pause();
    await _controller!.dispose();

    _controller = VideoPlayerController.network(newUrl);
    await _controller!.initialize();
    await _controller!.seekTo(oldPosition);
    if (wasPlaying) {
      _controller!.play();
    }

    setState(() {
      manualPause = !wasPlaying;
      _currentQualityUrl = newUrl;
    });

    _controller!.addListener(() {
      if (!mounted) return;
      final value = _controller!.value;
      if (!isSeeking) {
        setState(() {
          _currentPosition = value.position;
        });
      }
      if (value.position >= value.duration && !manualPause) {
        setState(() {
          manualPause = true;
        });
      }
    });
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 20),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Text(
                  'Playback Speed',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
                Wrap(
                  spacing: 10,
                  children: [0.5, 1.0, 1.5, 2.0].map((speed) {
                    return ChoiceChip(
                      checkmarkColor: Colors.white,
                      label: Text('${speed}x'),
                      selected: _controller!.value.playbackSpeed == speed,
                      onSelected: (selected) {
                        _controller!.setPlaybackSpeed(speed);
                        Navigator.pop(context); // Close sheet
                      },
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6.0),
                        side: BorderSide(
                          color: Color.fromARGB(
                            255,
                            49,
                            49,
                            49,
                          ), // Border color
                          width: 0.4,
                        ),
                      ),
                      selectedColor: Color(0xFF6153FF),
                      backgroundColor: Color.fromARGB(255, 41, 41, 41),
                      labelStyle: const TextStyle(color: Colors.white),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Other Settings',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
                ListTile(
                  title: const Text(
                    'Quality',
                    style: TextStyle(color: Colors.white),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.white,
                  ),
                  onTap: () {
                    if (_qualityVariants.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("No quality variants available"),
                        ),
                      );
                      return;
                    }

                    showModalBottomSheet(
                      context: context,
                      backgroundColor: Colors.grey[900],
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(20),
                        ),
                      ),
                      builder: (context) {
                        return ListView(
                          shrinkWrap: true,
                          children: [
                            // Optional: Add "Auto" at the top
                            ListTile(
                              title: const Text(
                                'Auto',
                                style: TextStyle(color: Colors.white),
                              ),
                              trailing: _currentQualityUrl == _masterUrl
                                  ? const Icon(
                                      Icons.check,
                                      color: Color(0xFF6153FF),
                                    )
                                  : null,
                              onTap: () {
                                _switchQuality(_masterUrl!);
                                Navigator.pop(context);
                              },
                            ),
                            const Divider(color: Colors.white24),

                            // Quality options
                            ..._qualityVariants.map((variant) {
                              final isSelected =
                                  _currentQualityUrl == variant['url'];
                              return ListTile(
                                title: Text(
                                  variant['resolution']!,
                                  style: const TextStyle(color: Colors.white),
                                ),
                                trailing: isSelected
                                    ? const Icon(
                                        Icons.check,
                                        color: Color(0xFF6153FF),
                                      )
                                    : null,
                                onTap: () {
                                  _switchQuality(variant['url']!);
                                  Navigator.pop(context);
                                },
                              );
                            }).toList(),
                          ],
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 5),

                Row(
                  spacing: 12.0,
                  children: [
                    Container(
                      margin: EdgeInsets.only(left: 15.0),
                      child: Text(
                        'Subtitle',
                        style: TextStyle(fontSize: 16, color: Colors.white),
                      ),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12.0,
                        vertical: 5.0,
                      ),
                      decoration: BoxDecoration(
                        color: Color(0xFF6153FF),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: widget.subtitleUrl.isNotEmpty
                          ? Text(
                              "English",
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                              ),
                            )
                          : Text(
                              'None',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                              ),
                            ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _togglePiP() {}

  void _toggleFullScreen() {
    setState(() {
      _isFullScreen = !_isFullScreen;

      if (_isFullScreen) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeRight,
          DeviceOrientation.landscapeLeft,
        ]);
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          SystemChrome.setSystemUIOverlayStyle(
            const SystemUiOverlayStyle(
              statusBarColor: Colors.white,
              statusBarIconBrightness: Brightness.dark,
            ),
          );
        });
      }
    });
  }

  void _toggleMute() {
    setState(() {
      if (_controller!.value.volume == 0.0) {
        _controller!.setVolume(1.0); // Unmute
      } else {
        _controller!.setVolume(0.0); // Mute
      }
    });
  }

  void _togglePlayPause() {
    setState(() {
      if (_controller!.value.isPlaying) {
        _controller!.pause();
        manualPause = true; // user paused manually
      } else {
        _controller!.play();
        manualPause = false; // playing, so not manually paused
      }
    });
  }

  void _showSkipOverlay(bool isLeft) {
    _overlayTimer?.cancel();
    setState(() {
      _showLeftOverlay = isLeft;
      _showRightOverlay = !isLeft;
    });

    _overlayTimer = Timer(_overlayDuration, () {
      setState(() {
        _showLeftOverlay = false;
        _showRightOverlay = false;
      });
    });
  }

  void _seekRelative(int seconds) {
    final current = _controller!.value.position;
    final target = current + Duration(seconds: seconds);

    _controller!.seekTo(target < Duration.zero ? Duration.zero : target);
  }

  @override
  Widget build(BuildContext context) {
    final value = _controller!.value;
    final isBuffering = !manualPause && !value.isPlaying && value.isInitialized;

    return MaterialApp(
      title: 'Video Demo',
      home: SafeArea(
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: value.isInitialized
                ? GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () {
                      setState(() {
                        _showControls = !_showControls;
                      });
                    },
                    onDoubleTapDown: (details) {
                      final screenWidth = MediaQuery.of(context).size.width;
                      final dx = details.globalPosition.dx;

                      if (dx < screenWidth / 2) {
                        _seekRelative(-10); // ⏪ Left double-tap
                        _showSkipOverlay(true);
                      } else {
                        _seekRelative(10); // ⏩ Right double-tap
                        _showSkipOverlay(false);
                      }
                    },
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Stack(
                          alignment: Alignment.center,
                          children: [
                            Stack(
                              alignment: Alignment.bottomCenter,
                              children: [
                                AspectRatio(
                                  aspectRatio: 16 / 10,
                                  child: VideoPlayer(_controller!),
                                ),
                                if (_currentSubtitle.isNotEmpty)
                                  Container(
                                    padding: EdgeInsets.all(8),
                                    color: Colors.black.withOpacity(0.6),
                                    child: Text(
                                      _currentSubtitle,
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                              ],
                            ),
                            if (_showLeftOverlay)
                              Positioned(
                                left: 40,
                                child: AnimatedOpacity(
                                  opacity: _showLeftOverlay ? 1.0 : 0.0,
                                  duration: Duration(milliseconds: 300),
                                  child: Container(
                                    padding: EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Colors.black45,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      children: const [
                                        Icon(
                                          Icons.replay_10,
                                          color: Colors.white,
                                          size: 30,
                                        ),
                                        SizedBox(width: 8),
                                        Text(
                                          "10s",
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 20,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),

                            // Right double-tap overlay
                            if (_showRightOverlay)
                              Positioned(
                                right: 40,
                                child: AnimatedOpacity(
                                  opacity: _showRightOverlay ? 1.0 : 0.0,
                                  duration: Duration(milliseconds: 300),
                                  child: Container(
                                    padding: EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Colors.black45,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      children: const [
                                        Text(
                                          "10s",
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 20,
                                          ),
                                        ),
                                        SizedBox(width: 8),
                                        Icon(
                                          Icons.forward_10,
                                          color: Colors.white,
                                          size: 30,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),

                        if (_showControls)
                          Container(
                            width: double.infinity,
                            height: double.infinity,
                            color: Colors.black.withOpacity(0.2),
                          ),

                        if (isBuffering)
                          Center(
                            child: Image.asset(
                              'assets/loading.gif',
                              width: 100,
                              height: 100,
                            ),
                          ),

                        if ((!value.isPlaying && !isBuffering) ||
                            value.isCompleted)
                          GestureDetector(
                            onTap: _togglePlayPause,
                            child: Image.asset(
                              'assets/play.png',
                              width: 64,
                              height: 64,
                            ),
                          ),

                        if (_showControls)
                          Positioned(
                            bottom: 0,
                            left: 5,
                            right: 5,
                            child: Column(
                              children: [
                                SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 6.0,
                                    thumbShape: ImageSliderThumb(
                                      imagePath: 'assets/thumb.png',
                                      thumbRadius: 12,
                                    ),
                                    overlayShape: const RoundSliderOverlayShape(
                                      overlayRadius: 14.0,
                                    ),
                                    trackShape:
                                        const RoundedRectSliderTrackShape(),
                                    activeTrackColor: Color(0xFF6153FF),
                                    inactiveTrackColor: Colors.white38,
                                    thumbColor: Color(0xFF6153FF),
                                    overlayColor: Color(
                                      0xFF6153FF,
                                    ).withOpacity(0.2),
                                  ),
                                  child: Slider(
                                    value: isSeeking
                                        ? _currentPosition.inMilliseconds
                                              .toDouble()
                                        : _controller!
                                              .value
                                              .position
                                              .inMilliseconds
                                              .toDouble(),
                                    max: _controller!
                                        .value
                                        .duration
                                        .inMilliseconds
                                        .toDouble(),
                                    onChangeStart: (_) {
                                      setState(() {
                                        isSeeking = true;
                                      });
                                    },
                                    onChanged: (value) {
                                      setState(() {
                                        _currentPosition = Duration(
                                          milliseconds: value.toInt(),
                                        );
                                      });
                                    },
                                    onChangeEnd: (value) {
                                      _controller!
                                          .seekTo(
                                            Duration(
                                              milliseconds: value.toInt(),
                                            ),
                                          )
                                          .then((_) {
                                            setState(() {
                                              isSeeking = false;
                                            });
                                          });
                                    },
                                  ),
                                ),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      children: [
                                        IconButton(
                                          iconSize: 27,
                                          icon: Icon(
                                            value.isPlaying
                                                ? Icons.pause
                                                : Icons.play_arrow,
                                            color: Colors.white,
                                          ),
                                          onPressed: _togglePlayPause,
                                        ),
                                        IconButton(
                                          iconSize: 27,
                                          icon: Icon(
                                            value.volume == 0.0
                                                ? Icons.volume_off
                                                : Icons.volume_up,
                                            color: Colors.white,
                                          ),
                                          onPressed: _toggleMute,
                                        ),
                                        Text(
                                          _formatDuration(_currentPosition)!,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 15,
                                          ),
                                        ),
                                        Text(
                                          '/${_formatDuration(value.duration)!}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 15,
                                          ),
                                        ),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        IconButton(
                                          iconSize: 27,
                                          icon: const Icon(
                                            Icons.settings,
                                            color: Colors.white,
                                          ),
                                          onPressed: _openSettings,
                                        ),
                                        IconButton(
                                          iconSize: 27,
                                          icon: const Icon(
                                            Icons.picture_in_picture_alt,
                                            color: Colors.white,
                                          ),
                                          onPressed: _togglePiP,
                                        ),
                                        IconButton(
                                          iconSize: 27,
                                          icon: Icon(
                                            _isFullScreen
                                                ? Icons.fullscreen_exit
                                                : Icons.fullscreen,
                                            color: Colors.white,
                                          ),
                                          onPressed: _toggleFullScreen,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  )
                : const CircularProgressIndicator(),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Color(0xFF121212),
          statusBarIconBrightness: Brightness.light,
        ),
      );
    });
    _overlayTimer?.cancel();
    _subtitleTimer?.cancel();
    _controller!.dispose();
    super.dispose();
  }
}
