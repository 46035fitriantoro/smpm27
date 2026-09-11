import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // === SECURITY: Keep screen on during exam ===
  WakelockPlus.enable();

  // === SECURITY: Lock orientation to portrait ===
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // === PERSISTENCE: Enable cookies for session persistence ===
  await CookieManager.instance().setCookie(
    url: WebUri("https://kkmp-harmul.id"),
    name: "smpm27_persistent",
    value: "1",
    expiresDate: DateTime.now().millisecondsSinceEpoch + (86400 * 30 * 1000),
    isSecure: true,
    isHttpOnly: false,
  );

  // === SECURITY: Enter immersive sticky mode (hide status & nav bar) ===
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // Request permissions
  try {
    var locStatus = await Permission.location.request();
    if (locStatus.isDenied) {
      locStatus = await Permission.location.request();
    }
    await [
      Permission.camera,
      Permission.storage,
      Permission.photos,
      Permission.microphone,
    ].request();
  } catch (e) {
    debugPrint("Permission error: $e");
  }

  runApp(const SMPM27App());
}

class SMPM27App extends StatelessWidget {
  const SMPM27App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(scaffoldBackgroundColor: Colors.white),
      home: const ExamWebView(),
    );
  }
}

class ExamWebView extends StatefulWidget {
  const ExamWebView({super.key});

  @override
  State<ExamWebView> createState() => _ExamWebViewState();
}

class _ExamWebViewState extends State<ExamWebView> with WidgetsBindingObserver {
  InAppWebViewController? webViewController;
  bool _showErrorOverlay = false;
  bool _isRetrying = false;
  bool _showExitDialog = false;
  bool _showSwitchWarning = false;
  int _switchCount = 0;

  static const _targetUrl = "https://kkmp-harmul.id/smpm27/dashboard-mobile";
  static const _securityChannel = MethodChannel('id.smpmuh27.app/security');
  Position? _lastPosition;

  // === SECURITY: Track app lifecycle ===
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initSecurity();
  }

  // === SECURITY: Initialize native security features after engine is ready ===
  Future<void> _initSecurity() async {
    // Enable FLAG_SECURE (blocks screenshot & screen recording)
    try {
      await _securityChannel.invokeMethod('enableSecureFlag');
    } catch (e) {
      debugPrint("Failed to enable secure flag: $e");
    }

    // Start Lock Task Mode (prevents opening other apps)
    try {
      await _securityChannel.invokeMethod('startLockTask');
    } catch (e) {
      debugPrint("Failed to start lock task: $e");
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    super.dispose();
  }

  // === SECURITY: Detect app switching ===
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      // User left the app - increment switch count and report
      setState(() {
        _switchCount++;
      });

      // Report to server via JavaScript
      _reportAppSwitch();

      // Show warning when user comes back
      if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
        setState(() { _showSwitchWarning = true; });
      }
    }

    if (state == AppLifecycleState.resumed) {
      // User came back - show warning briefly then hide
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted) {
          setState(() { _showSwitchWarning = false; });
        }
      });
    }
  }

  // === SECURITY: Report app switch to server ===
  Future<void> _reportAppSwitch() async {
    try {
      webViewController?.evaluateJavascript(source: """
        if (typeof window.onAppSwitch === 'function') {
          window.onAppSwitch($_switchCount);
        }
      """);
    } catch (e) {
      debugPrint("Failed to report app switch: $e");
    }
  }

  // === SECURITY: Disable back button ===
  Future<bool> _onWillPop() async {
    if (_showExitDialog) return false;

    setState(() { _showExitDialog = true; });

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Keluar Aplikasi?'),
        content: const Text('Apakah anda yakin ingin keluar dari aplikasi?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () async {
              // Report exit attempt to server before closing
              await _reportAppExit();
              Navigator.of(ctx).pop(true);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Keluar'),
          ),
        ],
      ),
    );

    setState(() { _showExitDialog = false; });

    if (result == true) {
      // === SECURITY: Disable lock task before exit ===
      try {
        await _securityChannel.invokeMethod('stopLockTask');
      } catch (e) {
        debugPrint("Failed to stop lock task: $e");
      }

      WakelockPlus.disable();
      SystemNavigator.pop();
      return true;
    }
    return false;
  }

  // === SECURITY: Report app exit to server ===
  Future<void> _reportAppExit() async {
    try {
      webViewController?.evaluateJavascript(source: """
        if (typeof window.onAppExit === 'function') {
          window.onAppExit();
        }
      """);
    } catch (e) {
      debugPrint("Failed to report app exit: $e");
    }
  }

  // === SECURITY: Disable multi-window / split screen ===
  // Handled via AndroidManifest.xml: resizeableActivity="false"

  Future<void> _retryConnection() async {
    setState(() { _isRetrying = true; });

    try {
      final response = await Dio().head(
        _targetUrl,
        options: Options(
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      if ([200, 301, 302].contains(response.statusCode)) {
        setState(() { _showErrorOverlay = false; _isRetrying = false; });
        webViewController?.loadUrl(
          urlRequest: URLRequest(url: WebUri(_targetUrl))
        );
        return;
      }
    } catch (_) {}

    setState(() { _isRetrying = false; });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Koneksi masih terputus. Silakan coba lagi.")),
      );
    }
  }

  Future<Map<String, dynamic>> _getNativeLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return {'error': 'GPS mati', 'lat': 0, 'lng': 0};
    }
    try {
      Position pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      _lastPosition = pos;
      return {'lat': pos.latitude, 'lng': pos.longitude, 'accuracy': pos.accuracy};
    } catch (e) {
      if (_lastPosition != null) {
        return {'lat': _lastPosition!.latitude, 'lng': _lastPosition!.longitude, 'accuracy': _lastPosition!.accuracy, 'cached': true};
      }
      return {'error': e.toString(), 'lat': 0, 'lng': 0};
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _onWillPop();
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              InAppWebView(
                initialUrlRequest: URLRequest(
                  url: WebUri(_targetUrl)
                ),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  useOnDownloadStart: true,
                  allowsInlineMediaPlayback: true,
                  mediaPlaybackRequiresUserGesture: false,
                  disableDefaultErrorPage: true,
                  geolocationEnabled: true,

                  // === PERSISTENCE: Cookies handled via CookieManager in main() ===

                  // === SECURITY: Anti copy paste ===
                  supportZoom: false,
                  builtInZoomControls: false,
                  displayZoomControls: false,
                  useWideViewPort: false,
                  loadWithOverviewMode: false,

                  // === SECURITY: Disable file access ===
                  allowFileAccess: false,
                  allowFileAccessFromFileURLs: false,
                  allowUniversalAccessFromFileURLs: false,

                  // === SECURITY: Disable long press (text selection) ===
                  useHybridComposition: true,
                ),
                onReceivedError: (controller, request, error) {
                  if (request.isForMainFrame ?? true) {
                    setState(() { _showErrorOverlay = true; });
                  }
                },
                onWebViewCreated: (controller) {
                  webViewController = controller;

                  // === SECURITY: Disable text selection via JavaScript ===
                  controller.addUserScript(userScript: UserScript(
                    source: """
                    (function() {
                      // Disable text selection
                      document.addEventListener('selectstart', function(e) { e.preventDefault(); });
                      document.addEventListener('mousedown', function(e) {
                        if (e.target.tagName !== 'INPUT' && e.target.tagName !== 'TEXTAREA') {
                          e.preventDefault();
                        }
                      });

                      // Disable copy
                      document.addEventListener('copy', function(e) { e.preventDefault(); });

                      // Disable cut
                      document.addEventListener('cut', function(e) { e.preventDefault(); });

                      // Disable paste
                      document.addEventListener('paste', function(e) { e.preventDefault(); });

                      // Disable right click context menu
                      document.addEventListener('contextmenu', function(e) { e.preventDefault(); });

                      // Disable keyboard shortcuts (Ctrl+C, Ctrl+V, Ctrl+U, Ctrl+S, F12, etc.)
                      document.addEventListener('keydown', function(e) {
                        // Ctrl/Cmd combinations
                        if (e.ctrlKey || e.metaKey) {
                          var blocked = ['c', 'v', 'x', 'a', 'u', 's', 'p', 'j'];
                          if (blocked.indexOf(e.key.toLowerCase()) !== -1) {
                            e.preventDefault();
                            e.stopPropagation();
                            return false;
                          }
                        }
                        // F12, F5, F11
                        if ([116, 123, 122].indexOf(e.keyCode) !== -1) {
                          e.preventDefault();
                          e.stopPropagation();
                          return false;
                        }
                        // Print screen
                        if (e.keyCode === 44) {
                          e.preventDefault();
                          return false;
                        }
                      });

                      // === SECURITY: Anti inspect element ===
                      // Disable DevTools
                      Object.defineProperty(window, 'devtools', { get: function() { return undefined; } });

                      // Override console methods to prevent info leakage
                      var noop = function() {};
                      console.log = noop;
                      console.warn = noop;
                      console.error = noop;
                      console.info = noop;
                    })();
                    """,
                    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                  ));

                  // === SECURITY: Inject geolocation override ===
                  controller.addJavaScriptHandler(handlerName: 'getNativeLocation', callback: (args) async {
                    return await _getNativeLocation();
                  });

                  // Handler: Download PDF
                  controller.addJavaScriptHandler(handlerName: 'prosesDownload', callback: (args) async {
                    String fileUrl = args[0];
                    String fileName = args[1];

                    debugPrint("Memulai download: $fileName");

                    try {
                      Directory? tempDir = await getExternalStorageDirectory();
                      String fullPath = "${tempDir!.path}/$fileName";

                      Dio dio = Dio();
                      await dio.download(fileUrl, fullPath);

                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text("Berhasil diunduh: $fileName"),
                            action: SnackBarAction(
                              label: "BUKA",
                              onPressed: () async {
                                final Uri uri = Uri.parse(fullPath);
                                if (await canLaunchUrl(uri)) {
                                  await launchUrl(uri);
                                }
                              },
                            ),
                          ),
                        );
                      }

                      await SharePlus.instance.share(ShareParams(files: [XFile(fullPath)], text: 'Laporan PDF'));

                    } catch (e) {
                      debugPrint("Gagal Download: $e");
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("Gagal mengunduh file.")),
                        );
                      }
                    }
                  });

                  // === SECURITY: Inject geolocation JS override ===
                  controller.addUserScript(userScript: UserScript(
                    source: """
                    (function() {
                      function nativePos() {
                        return window.flutter_inappwebview.callHandler('getNativeLocation').then(function(pos) {
                          if (pos && !pos.error) return {
                            coords: {
                              latitude: pos.lat,
                              longitude: pos.lng,
                              accuracy: pos.accuracy || 50,
                              altitude: null, altitudeAccuracy: null,
                              heading: null, speed: null
                            },
                            timestamp: Date.now()
                          };
                          return null;
                        });
                      }
                      if (navigator.geolocation.getCurrentPosition) {
                        var origG = navigator.geolocation.getCurrentPosition.bind(navigator.geolocation);
                        navigator.geolocation.getCurrentPosition = function(s, e, o) {
                          origG(s, function(err) {
                            if (window.flutter_inappwebview) {
                              nativePos().then(function(p) { if (p && s) s(p); else if (e) e(err); }).catch(function() { if (e) e(err); });
                            } else { if (e) e(err); }
                          }, o);
                        };
                      }
                      if (navigator.geolocation.watchPosition) {
                        var origW = navigator.geolocation.watchPosition.bind(navigator.geolocation);
                        var watchCount = 0;
                        navigator.geolocation.watchPosition = function(s, e, o) {
                          var wid = origW(s, function(err) {
                            if (window.flutter_inappwebview) {
                              var id = ++watchCount;
                              nativePos().then(function(p) {
                                if (p && s) s(p);
                                var interval = setInterval(function() {
                                  if (!window['_gpsWatch_' + id]) { clearInterval(interval); return; }
                                  nativePos().then(function(p2) { if (p2 && s) s(p2); });
                                }, 10000);
                                window['_gpsWatch_' + id + '_interval'] = interval;
                                window['_gpsWatch_' + id] = true;
                              }).catch(function() { if (e) e(err); });
                            } else { if (e) e(err); }
                          }, o);
                          var origCW = navigator.geolocation.clearWatch.bind(navigator.geolocation);
                          navigator.geolocation.clearWatch = function(id) {
                            origCW(id);
                            for (var key in window) {
                              if (key.indexOf('_gpsWatch_') === 0 && key.indexOf('_interval') > 0) {
                                var num = key.replace('_gpsWatch_', '').replace('_interval', '');
                                if (parseInt(num) <= id) {
                                  clearInterval(window[key]);
                                  delete window[key.replace('_interval', '')];
                                  delete window[key];
                                }
                              }
                            }
                          };
                          return wid;
                        };
                      }
                    })();
                    """,
                    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                  ));
                },
                onPermissionRequest: (controller, request) async {
                  return PermissionResponse(
                    resources: request.resources,
                    action: PermissionResponseAction.GRANT,
                  );
                },
                onGeolocationPermissionsShowPrompt: (controller, origin) async {
                  return GeolocationPermissionShowPromptResponse(
                    origin: origin,
                    allow: true,
                    retain: true,
                  );
                },
                onDownloadStartRequest: (controller, downloadStartRequest) async {
                  final url = downloadStartRequest.url;
                  if (await canLaunchUrl(url)) {
                    await launchUrl(url, mode: LaunchMode.externalApplication);
                  }
                },
              ),

              // === SECURITY: App switch warning overlay ===
              if (_showSwitchWarning)
                Container(
                  color: Colors.red.withOpacity(0.9),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.warning_amber_rounded, size: 64, color: Colors.white),
                          const SizedBox(height: 16),
                          const Text(
                            "PERINGATAN!",
                            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            "Anda terdeteksi meninggalkan aplikasi! Ketika ujian berlangsung peringatan ini akan terdeteksi oleh Pengawas.",
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 16, color: Colors.white),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            "Percobaan ke-$_switchCount",
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 14, color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // === ERROR OVERLAY ===
              if (_showErrorOverlay && !_showSwitchWarning)
                Container(
                  color: Colors.white,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 80,
                            height: 80,
                            margin: const EdgeInsets.only(bottom: 20),
                            decoration: const BoxDecoration(
                              color: Color(0xFFFFF3E0),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.wifi_off, size: 40, color: Color(0xFFE65100)),
                          ),
                          const Text("Koneksi Terputus",
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF333333))),
                          const SizedBox(height: 8),
                          const Text(
                            "Silakan periksa koneksi internet Anda,\nlalu coba lagi.",
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 14, color: Color(0xFF888888)),
                          ),
                          const SizedBox(height: 24),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _isRetrying ? null : _retryConnection,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF1976D2),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                disabledBackgroundColor: const Color(0xFF1976D2).withValues(alpha: 0.6),
                              ),
                              child: _isRetrying
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : const Text("Coba Lagi", style: TextStyle(fontSize: 15)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
