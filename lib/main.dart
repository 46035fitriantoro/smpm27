import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:geolocator/geolocator.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(scaffoldBackgroundColor: Colors.white),
    home: const MyWebView(),
  ));
}

class MyWebView extends StatefulWidget {
  const MyWebView({super.key});

  @override
  State<MyWebView> createState() => _MyWebViewState();
}

class _MyWebViewState extends State<MyWebView> {
  InAppWebViewController? webViewController;
  bool _showErrorOverlay = false;
  bool _isRetrying = false;

  static const _targetUrl = "https://kkmp-utanpanjang.com/barokah/customer";
  Position? _lastPosition;

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
        if (await webViewController?.canGoBack() ?? false) {
          webViewController?.goBack();
        } else {
          if (mounted) Navigator.of(context).pop();
        }
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
                ),
                onReceivedError: (controller, request, error) {
                  if (request.isForMainFrame ?? true) {
                    setState(() { _showErrorOverlay = true; });
                  }
                },
                onWebViewCreated: (controller) {
                  webViewController = controller;

                  controller.addJavaScriptHandler(handlerName: 'getNativeLocation', callback: (args) async {
                    return await _getNativeLocation();
                  });

                  // HANDLER: Download PDF
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

                  // Inject JS override for geolocation fallback
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
  // Override getCurrentPosition
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
  // Override watchPosition
  if (navigator.geolocation.watchPosition) {
    var origW = navigator.geolocation.watchPosition.bind(navigator.geolocation);
    var watchCount = 0;
    navigator.geolocation.watchPosition = function(s, e, o) {
      var wid = origW(s, function(err) {
        if (window.flutter_inappwebview) {
          var id = ++watchCount;
          nativePos().then(function(p) {
            if (p && s) s(p);
            // Poll every 10s
            var interval = setInterval(function() {
              if (!window['_gpsWatch_' + id]) { clearInterval(interval); return; }
              nativePos().then(function(p2) { if (p2 && s) s(p2); });
            }, 10000);
            window['_gpsWatch_' + id + '_interval'] = interval;
            window['_gpsWatch_' + id] = true;
          }).catch(function() { if (e) e(err); });
        } else { if (e) e(err); }
      }, o);
      // Wrap clearWatch
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
              if (_showErrorOverlay)
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