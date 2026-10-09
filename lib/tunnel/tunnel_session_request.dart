import 'connection_mode.dart';
import 'vpn_backend.dart';

/// параметры запуска туннеля (android tun и desktop proxy/tun)
class TunnelSessionRequest {
  final ConnectionMode mode;
  final VpnBackend vpnBackend;
  final String xrayConfig;

  /// Конфиг mihomo (когда [vpnBackend] == mihomo). JSON — ядро читает его как
  /// YAML, тот надмножество; см. MihomoConfigGen.
  final String? mihomoConfig;
  final int socksPort;
  final int httpPort;
  final String? singboxConfig;
  final List<String> excludePackages;
  final List<String> includePackages;
  final List<String> excludeProcesses;
  final List<String> includeProcesses;

  /// Extra per-network configs, generated for Android VPN mode only.
  /// Shape: {wifi|cellular: {config, backend, serverName}}.
  final Map<String, Map<String, String>> networkConfigs;

  /// Optional sing-box/libbox TUN config for per-app server routing on Android.
  final String? appRoutingConfig;

  /// Proxy-only core configs keyed by server id. Each has config/backend/name/SOCKS port.
  final Map<String, Map<String, dynamic>> appServerConfigs;
  final String? serverName;
  final bool systemProxy;

  /// Ядро: `chain` (xray → sing-box) или `keqrnel` (единое ядро). Дефолт `chain`.
  final String coreEngine;

  /// Дебаг-режим приложения. Включает то, что стоит денег в рантайме и нужно
  /// только для диагностики: поиск процесса-владельца соединения в sing-box
  /// (`find_process`) для дебаг-экрана «Соединения».
  final bool debugMode;

  const TunnelSessionRequest({
    required this.mode,
    this.vpnBackend = VpnBackend.xray,
    required this.xrayConfig,
    this.mihomoConfig,
    this.socksPort = 2080,
    this.httpPort = 2081,
    this.singboxConfig,
    this.excludePackages = const [],
    this.includePackages = const [],
    this.excludeProcesses = const [],
    this.includeProcesses = const [],
    this.networkConfigs = const {},
    this.appRoutingConfig,
    this.appServerConfigs = const {},
    this.serverName,
    this.systemProxy = true,
    this.coreEngine = 'chain',
    this.debugMode = false,
  });

  Map<String, dynamic> toMethodChannelArgs({
    required String socksUsername,
    required String socksPassword,
  }) =>
      {
        'connectionMode': mode.storageValue,
        'vpnBackend': vpnBackend.wireValue,
        'xrayConfig': xrayConfig,
        if (mihomoConfig != null && mihomoConfig!.isNotEmpty)
          'mihomoConfig': mihomoConfig,
        'socksPort': socksPort,
        if (singboxConfig != null && singboxConfig!.isNotEmpty)
          'singboxConfig': singboxConfig,
        'socksUsername': socksUsername,
        'socksPassword': socksPassword,
        'excludePackages': excludePackages,
        'includePackages': includePackages,
        'excludeProcesses': excludeProcesses,
        'includeProcesses': includeProcesses,
        if (networkConfigs.isNotEmpty) 'networkConfigs': networkConfigs,
        if (appRoutingConfig != null && appRoutingConfig!.isNotEmpty)
          'appRoutingConfig': appRoutingConfig,
        if (appServerConfigs.isNotEmpty) 'appServerConfigs': appServerConfigs,
        'systemProxy': systemProxy,
        'coreEngine': coreEngine,
        if (serverName != null && serverName!.isNotEmpty) 'serverName': serverName,
      };
}
