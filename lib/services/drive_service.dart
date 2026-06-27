import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';

class DriveService {
  // ─── Credentials ──────────────────────────────────────────
  static const _androidClientId =
      'CLIENDID';
  static const _desktopClientId =
      'CLIENTID';
  static const _desktopClientSecret = 'CLIENTSECRET';
  static const _redirectUri = 'http://localhost:8080';
  static const _tokenFile = 'drive_token.json';

  static String get _clientId =>
      Platform.isAndroid ? _androidClientId : _desktopClientId;

  // ─── State ─────────────────────────────────────────────────
  final _googleSignIn = GoogleSignIn(
    clientId: _androidClientId,
    scopes: ['https://www.googleapis.com/auth/drive.file'],
  );

  GoogleSignInAccount? _currentUser;
  Map<String, dynamic>? _desktopToken;

  bool get isSignedIn =>
      Platform.isAndroid ? _currentUser != null : _desktopToken != null;

  String? get userEmail => Platform.isAndroid
      ? _currentUser?.email
      : _desktopToken?['email'];

  final _statusController = StreamController<String>.broadcast();
  Stream<String> get status => _statusController.stream;

  // ─── Sign In ───────────────────────────────────────────────
  Future<bool> signIn() async {
    return Platform.isAndroid ? _signInAndroid() : _signInDesktop();
  }

  Future<bool> _signInAndroid() async {
    try {
      _currentUser = await _googleSignIn.signIn();
      return _currentUser != null;
    } catch (e) {
      _statusController.add('[Drive] Sign in failed: $e');
      return false;
    }
  }

  Future<bool> _signInDesktop() async {
    try {
      // Try saved token first
      final tokenFile = File(_tokenFile);
      if (await tokenFile.exists()) {
        final saved = jsonDecode(await tokenFile.readAsString());
        final refreshed = await _refreshToken(saved['refresh_token']);
        if (refreshed != null) {
          _desktopToken = refreshed;
          _statusController.add('[Drive] Signed in using saved token');
          return true;
        }
        await tokenFile.delete();
      }

      // Start local server to catch redirect
      final server = await HttpServer.bind('localhost', 8080);
      _statusController.add('[Drive] Opening browser for Google sign in...');

      // Build auth URL
      final authUrl = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': _clientId,
        'redirect_uri': _redirectUri,
        'response_type': 'code',
        'scope':
            'https://www.googleapis.com/auth/drive.file email profile',
        'access_type': 'offline',
        'prompt': 'consent',
      });

      await launchUrl(authUrl);

      // Wait for redirect with code
      String? code;
      await for (final request in server) {
        code = request.uri.queryParameters['code'];
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write('''
            <html>
              <body style="font-family:sans-serif;text-align:center;padding:40px;background:#111;color:#fff">
                <h2 style="color:#00C853">PocketServer</h2>
                <p>Authorization complete! You can close this tab.</p>
              </body>
            </html>
          ''')
          ..close();
        break;
      }
      await server.close();

      if (code == null) {
        _statusController.add('[Drive] No auth code received');
        return false;
      }

      // Exchange code for token
      final response = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        body: {
          'client_id': _clientId,
          'client_secret': _desktopClientSecret,
          'code': code,
          'grant_type': 'authorization_code',
          'redirect_uri': _redirectUri,
        },
      );

      if (response.statusCode != 200) {
        _statusController
            .add('[Drive] Token exchange failed: ${response.body}');
        return false;
      }

      _desktopToken = jsonDecode(response.body);
      await File(_tokenFile)
          .writeAsString(jsonEncode(_desktopToken));
      _statusController.add('[Drive] Signed in successfully!');
      return true;
    } catch (e) {
      _statusController.add('[Drive] Desktop sign in failed: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>?> _refreshToken(String refreshToken) async {
    try {
      final response = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        body: {
          'client_id': _clientId,
          'client_secret': _desktopClientSecret,
          'refresh_token': refreshToken,
          'grant_type': 'refresh_token',
        },
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        data['refresh_token'] = refreshToken;
        return data;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ─── Sign Out ──────────────────────────────────────────────
  Future<void> signOut() async {
    if (Platform.isAndroid) {
      await _googleSignIn.signOut();
      _currentUser = null;
    } else {
      _desktopToken = null;
      final tokenFile = File(_tokenFile);
      if (await tokenFile.exists()) await tokenFile.delete();
    }
  }

  // ─── Drive API Client ──────────────────────────────────────
  Future<drive.DriveApi?> _getDriveApi() async {
    if (Platform.isAndroid) {
      if (_currentUser == null) return null;
      final headers = await _currentUser!.authHeaders;
      return drive.DriveApi(_AuthClient(headers));
    } else {
      if (_desktopToken == null) return null;
      return drive.DriveApi(_AuthClient({
        'Authorization': 'Bearer ${_desktopToken!['access_token']}',
      }));
    }
  }

  // ─── Folder ────────────────────────────────────────────────
  Future<String?> _getOrCreateFolder(
    drive.DriveApi api,
    String folderName, {
    String? parentId,
  }) async {
    var query =
        "name = '$folderName' and mimeType = 'application/vnd.google-apps.folder' and trashed = false";
    if (parentId != null) {
      query += " and '$parentId' in parents";
    }
    final result =
        await api.files.list(q: query, $fields: 'files(id,name)');
    if (result.files != null && result.files!.isNotEmpty) {
      return result.files!.first.id;
    }
    final folder = drive.File()
      ..name = folderName
      ..mimeType = 'application/vnd.google-apps.folder';
    if (parentId != null) folder.parents = [parentId];
    final created = await api.files.create(folder);
    return created.id;
  }

  // ─── Zip ───────────────────────────────────────────────────
  Future<File> _zipDirectory(String sourcePath, String zipName) async {
    final zipPath = path.join(Directory.systemTemp.path, zipName);
    _statusController.add('[Drive] Zipping via WSL2...');

    // Use WSL2 zip command — much faster than Dart for WSL paths
    final result = await Process.run(
      'wsl.exe',
      ['-e', 'zip', '-r', '-1', '/tmp/$zipName', '.'],
      workingDirectory: sourcePath,
    );

    if (result.exitCode != 0) {
      throw Exception('Zip failed: ${result.stderr}');
    }

    // Copy from WSL2 temp to Windows temp
    final wslZipPath = r'\\wsl$\Ubuntu\tmp\' + zipName;
    await File(wslZipPath).copy(zipPath);

    // Clean up WSL2 temp file
    await Process.run('wsl.exe', ['-e', 'rm', '/tmp/$zipName']);

    return File(zipPath);
  }

  // ─── Backup ────────────────────────────────────────────────
  Future<bool> backup({
    required String serverPath,
    required String folderName,
    required int keepCount,
    String worldName = 'world',
    List<String>? includePaths,
  }) async {
    try {
      final api = await _getDriveApi();
      if (api == null) {
        _statusController.add('[Drive] Not signed in');
        return false;
      }

      final now = DateTime.now();
      final date =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final time =
          '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
      final zipName = '${worldName}_${date}_$time.zip';

      _statusController.add('[Drive] Zipping $worldName...');
      final zipFile = await _zipDirectory(serverPath, zipName);

      _statusController.add('[Drive] Uploading to Google Drive...');

      // Create parent folder → world subfolder
      final parentId = await _getOrCreateFolder(api, folderName);
      if (parentId == null) {
        _statusController.add('[Drive] Failed to get/create folder');
        return false;
      }
      final worldFolderId =
          await _getOrCreateFolder(api, worldName, parentId: parentId);
      if (worldFolderId == null) {
        _statusController.add('[Drive] Failed to get world folder');
        return false;
      }

      final driveFile = drive.File()
        ..name = zipName
        ..parents = [worldFolderId];

      await api.files.create(
        driveFile,
        uploadMedia: drive.Media(
          zipFile.openRead(),
          zipFile.lengthSync(),
        ),
      );

      _statusController.add('[Drive] Upload complete! → $folderName/$worldName/$zipName');
      await zipFile.delete();
      await _rotateBackups(api, worldFolderId, keepCount);
      return true;
    } catch (e) {
      _statusController.add('[Drive] Backup failed: $e');
      return false;
    }
  }
  
  // ─── Rotate Backups ────────────────────────────────────────
  Future<void> _rotateBackups(
      drive.DriveApi api, String folderId, int keepCount) async {
    final query =
        "'$folderId' in parents and name contains 'Backup_' and trashed = false";
    final result = await api.files.list(
      q: query,
      orderBy: 'createdTime desc',
      $fields: 'files(id,name)',
    );
    final files = result.files ?? [];
    if (files.length > keepCount) {
      for (final file in files.sublist(keepCount)) {
        await api.files.delete(file.id!);
        _statusController
            .add('[Drive] Deleted old backup: ${file.name}');
      }
    }
  }

  // List files/folders in a Drive folder
  Future<List<DriveItem>> listFolder(String? folderId) async {
    try {
      final api = await _getDriveApi();
      if (api == null) return [];

      var query =
          "trashed = false and mimeType != 'application/vnd.google-apps.shortcut'";
      if (folderId == null) {
        query += " and 'root' in parents";
      } else {
        query += " and '$folderId' in parents";
      }

      final result = await api.files.list(
        q: query,
        orderBy: 'folder,name',
        $fields:
            'files(id,name,mimeType,size,modifiedTime)',
      );

      return (result.files ?? []).map((f) {
        return DriveItem(
          id: f.id ?? '',
          name: f.name ?? '',
          isFolder: f.mimeType ==
              'application/vnd.google-apps.folder',
          size: int.tryParse(f.size ?? '0') ?? 0,
          modifiedTime: f.modifiedTime,
        );
      }).toList();
    } catch (e) {
      _statusController.add('[Drive] List error: $e');
      return [];
    }
  }

  // Download a file from Drive to a local temp path
  Future<String?> downloadFile({
    required String fileId,
    required String fileName,
    required Function(String) onStatus,
  }) async {
    try {
      final api = await _getDriveApi();
      if (api == null) return null;

      onStatus('[Drive] Downloading $fileName...');

      final media = await api.files.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;

      final tempPath =
          '${Directory.systemTemp.path}/$fileName';
      final file = File(tempPath);
      final sink = file.openWrite();

      await media.stream.pipe(sink);
      await sink.close();

      onStatus('[Drive] Download complete!');
      return tempPath;
    } catch (e) {
      _statusController.add('[Drive] Download error: $e');
      return null;
    }
  }
  
  void dispose() {
    _statusController.close();
  }
}

// ─── Auth HTTP Client ──────────────────────────────────────
class _AuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final _inner = http.Client();
  _AuthClient(this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _inner.send(request);
  }
}
class DriveItem {
  final String id;
  final String name;
  final bool isFolder;
  final int size;
  final DateTime? modifiedTime;

  DriveItem({
    required this.id,
    required this.name,
    required this.isFolder,
    required this.size,
    this.modifiedTime,
  });

  String get formattedSize {
    if (size < 1024) return '${size}B';
    if (size < 1024 * 1024) {
      return '${(size / 1024).toStringAsFixed(1)}KB';
    }
    return '${(size / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
}