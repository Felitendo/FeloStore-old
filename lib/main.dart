import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:obtainium/pages/home.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/native_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:background_fetch/background_fetch.dart';
import 'package:easy_localization/easy_localization.dart';

import 'package:flutter/services.dart' show rootBundle; // Specific import

import 'package:obtainium/pages/apps.dart';

List<MapEntry<Locale, String>> supportedLocales = const [
  MapEntry(Locale('en'), 'English'),
  MapEntry(Locale('zh'), '简体中文'),
  MapEntry(Locale('it'), 'Italiano'),
  MapEntry(Locale('ja'), '日本語'),
  MapEntry(Locale('hu'), 'Magyar'),
  MapEntry(Locale('de'), 'Deutsch'),
  MapEntry(Locale('fa'), 'فارسی'),
  MapEntry(Locale('fr'), 'Français'),
  MapEntry(Locale('es'), 'Español'),
  MapEntry(Locale('pl'), 'Polski'),
  MapEntry(Locale('ru'), 'Русский'),
  MapEntry(Locale('bs'), 'Bosanski'),
  MapEntry(Locale('pt'), 'Brasileiro'),
  MapEntry(Locale('cs'), 'Česky'),
  MapEntry(Locale('sv'), 'Svenska'),
  MapEntry(Locale('nl'), 'Nederlands'),
  MapEntry(Locale('vi'), 'Tiếng Việt'),
  MapEntry(Locale('tr'), 'Türkçe'),
  MapEntry(Locale('uk'), 'Українська'),
  MapEntry(Locale('da'), 'Dansk'),
];
const fallbackLocale = Locale('en');
const localeDir = 'assets/translations';
var fdroid = false;

final globalNavigatorKey = GlobalKey<NavigatorState>();

Future<void> loadTranslations() async {
  // Initialize settings to get the forced locale if any.
  var s = SettingsProvider();
  await s.initializeSettings();
  var forceLocale = s.forcedLocale;
}

@pragma('vm:entry-point')
void backgroundFetchHeadlessTask(HeadlessTask task) async {
  String taskId = task.taskId;
  bool isTimeout = task.timeout;
  if (isTimeout) {
    print('BG update task timed out.');
    BackgroundFetch.finish(taskId);
    return;
  }
  await bgUpdateCheck(taskId, null);
  BackgroundFetch.finish(taskId);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    ByteData data =
        await PlatformAssetBundle().load('assets/ca/lets-encrypt-r3.pem');
    SecurityContext.defaultContext
        .setTrustedCertificatesBytes(data.buffer.asUint8List());
  } catch (e) {
    // Already added, do nothing (see #375)
  }
  await EasyLocalization.ensureInitialized();
  if ((await DeviceInfoPlugin().androidInfo).version.sdkInt >= 29) {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(systemNavigationBarColor: Colors.transparent),
    );
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (context) => AppsProvider()),
      ChangeNotifierProvider(create: (context) => SettingsProvider()),
      Provider(create: (context) => NotificationsProvider()),
      Provider(create: (context) => LogsProvider())
    ],
    child: EasyLocalization(
        supportedLocales: supportedLocales.map((e) => e.key).toList(),
        path: localeDir,
        fallbackLocale: fallbackLocale,
        useOnlyLangCode: true,
        child: const Obtainium()),
  ));
  BackgroundFetch.registerHeadlessTask(backgroundFetchHeadlessTask);
}

class Obtainium extends StatefulWidget {
  const Obtainium({super.key});

  @override
  State<Obtainium> createState() => _ObtainiumState();
}

class _ObtainiumState extends State<Obtainium> {
  var existingUpdateInterval = -1;

  @override
  void initState() {
    super.initState();
    initPlatformState();
    initFirstRun();
  }

  Future<void> initPlatformState() async {
    await BackgroundFetch.configure(
        BackgroundFetchConfig(
            minimumFetchInterval: 15,
            stopOnTerminate: false,
            startOnBoot: true,
            enableHeadless: true,
            requiresBatteryNotLow: false,
            requiresCharging: false,
            requiresStorageNotLow: false,
            requiresDeviceIdle: false,
            requiredNetworkType: NetworkType.ANY), (String taskId) async {
      await bgUpdateCheck(taskId, null);
      BackgroundFetch.finish(taskId);
    }, (String taskId) async {
      context.read<LogsProvider>().add('BG update task timed out.');
      BackgroundFetch.finish(taskId);
    });
    if (!mounted) return;
  }

  Future<void> initFirstRun() async {
    SettingsProvider settingsProvider = context.read<SettingsProvider>();
    bool isFirstRun = settingsProvider.checkAndFlipFirstRun();
    if (isFirstRun) {
      await loadImportConfig(context);
    }
  }

  Future<void> loadImportConfig(BuildContext context) async {
    try {
      const configFilePath = 'assets/config.json';
      String data = await rootBundle.loadString(configFilePath);
      jsonDecode(data);
      var appsProvider = context.read<AppsProvider>();
      var settingsProvider = context.read<SettingsProvider>();
      var value = await appsProvider.import(data);
      var cats = settingsProvider.categories;
      appsProvider.apps.forEach((key, value) {
        for (var c in value.app.categories) {
          if (!cats.containsKey(c)) {
            cats[c] = generateRandomLightColor().value;
          }
        }
      });
      appsProvider.addMissingCategories(settingsProvider);
      showMessage(
        '${tr('importedX', args: [plural('apps', value.key.length)])}${value.value ? ' + ${tr('settings')}' : ''}',
        context,
      );
    } catch (e) {
      showError(e, context);
    }
  }

  void showMessage(String message, BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void showError(dynamic error, BuildContext context) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Error: $error')));
  }

  Color generateRandomLightColor() {
    final random = Random();
    return Color.fromRGBO(
      200 + random.nextInt(55),
      200 + random.nextInt(55),
      200 + random.nextInt(55),
      1,
    );
  }

  @override
  Widget build(BuildContext context) {
    SettingsProvider settingsProvider = context.watch<SettingsProvider>();
    AppsProvider appsProvider = context.read<AppsProvider>();
    LogsProvider logs = context.read<LogsProvider>();

    if (settingsProvider.prefs == null) {
      settingsProvider.initializeSettings();
    } else {
      bool isFirstRun = settingsProvider.checkAndFlipFirstRun();
      if (isFirstRun) {
        logs.add('This is the first ever run of Obtainium.');
        Permission.notification.request();
        if (!fdroid) {
          getInstalledInfo(obtainiumId).then((value) {
            if (value?.versionName != null) {
              appsProvider.saveApps([
                App(
                    obtainiumId,
                    obtainiumUrl,
                    'ImranR98',
                    'Obtainium',
                    value!.versionName,
                    value.versionName!,
                    [],
                    0,
                    {
                      'versionDetection': true,
                      'apkFilterRegEx': 'fdroid',
                      'invertAPKFilter': true
                    },
                    null,
                    false)
              ], onlyIfExists: false);
            }
          }).catchError((err) {
            print(err);
          });
        }
      }
      if (!supportedLocales
              .map((e) => e.key.languageCode)
              .contains(context.locale.languageCode) ||
          (settingsProvider.forcedLocale == null &&
              context.deviceLocale.languageCode !=
                  context.locale.languageCode)) {
        settingsProvider.resetLocaleSafe(context);
      }
    }

    return DynamicColorBuilder(
        builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
      ColorScheme lightColorScheme;
      ColorScheme darkColorScheme;
      if (lightDynamic != null &&
          darkDynamic != null &&
          settingsProvider.useMaterialYou) {
        lightColorScheme = lightDynamic.harmonized();
        darkColorScheme = darkDynamic.harmonized();
      } else {
        lightColorScheme =
            ColorScheme.fromSeed(seedColor: settingsProvider.themeColor);
        darkColorScheme = ColorScheme.fromSeed(
            seedColor: settingsProvider.themeColor,
            brightness: Brightness.dark);
      }

      if (settingsProvider.useBlackTheme) {
        darkColorScheme =
            darkColorScheme.copyWith(surface: Colors.black).harmonized();
      }

      if (settingsProvider.useSystemFont) NativeFeatures.loadSystemFont();

      return MaterialApp(
          title: 'Obtainium',
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          navigatorKey: globalNavigatorKey,
          theme: ThemeData(
              useMaterial3: true,
              colorScheme: settingsProvider.theme == ThemeSettings.dark
                  ? darkColorScheme
                  : lightColorScheme,
              fontFamily:
                  settingsProvider.useSystemFont ? 'SystemFont' : 'Metropolis'),
          darkTheme: ThemeData(
              useMaterial3: true,
              colorScheme: settingsProvider.theme == ThemeSettings.light
                  ? lightColorScheme
                  : darkColorScheme,
              fontFamily:
                  settingsProvider.useSystemFont ? 'SystemFont' : 'Metropolis'),
          home: Shortcuts(shortcuts: <LogicalKeySet, Intent>{
            LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
          }, child: const HomePage()));
    });
  }
}