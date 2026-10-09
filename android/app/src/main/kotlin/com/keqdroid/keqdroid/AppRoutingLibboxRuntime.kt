package com.keqdroid.keqdroid

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.ParcelFileDescriptor
import android.system.OsConstants
import android.util.Log
import io.nekohasekai.libbox.BridgeSession
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LibboxNotification
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NetworkInterface as LibboxNetworkInterface
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.io.File
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.util.Collections

/**
 * Owns the single Android TUN used when apps are assigned to different servers.
 * Each server itself stays in an existing proxy-only Xray/mihomo core; libbox
 * only identifies Android package owners and sends packets to their local SOCKS
 * outbounds.
 */
internal class AppRoutingLibboxRuntime(
    private val vpn: KeqdisVpnService,
) : PlatformInterface, CommandServerHandler, AutoCloseable {

    private var commandServer: CommandServer? = null
    private var tunDescriptor: ParcelFileDescriptor? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile private var closed = false

    fun start(config: String) {
        check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            "Per-app server routing requires Android 10 or newer."
        }
        synchronized(SETUP_LOCK) {
            if (!boxInitialized) {
                val options = SetupOptions().apply {
                    setBasePath(vpn.filesDir.absolutePath)
                    setWorkingPath(vpn.getDir("app-routing-libbox", 0).absolutePath)
                    setTempPath(vpn.cacheDir.absolutePath)
                    setFixAndroidStack(true)
                }
                Libbox.setup(options)
                boxInitialized = true
                NativeLog.i("KEQDIS", "app routing: libbox ${Libbox.version()}")
            }
        }

        val server = CommandServer(this, this)
        commandServer = server
        server.start()
        server.checkConfig(config)
        server.startOrReloadService(config, OverrideOptions())
        startInterfaceMonitor()
    }

    override fun openTun(options: TunOptions): Int {
        check(!closed) { "Per-app routing runtime is already closed." }
        val mtu = options.mtu.takeIf { it in 576..9000 } ?: KeqdisVpnService.TUN_MTU
        val builder = vpn.Builder()
            .setSession("KEQDIS app routing")
            .setMtu(mtu)
            .setBlocking(false)

        val ipv4 = options.inet4Address
        while (ipv4.hasNext()) {
            val prefix = ipv4.next()
            builder.addAddress(prefix.address(), prefix.prefix())
        }

        val ipv6 = options.inet6Address
        while (ipv6.hasNext()) {
            val prefix = ipv6.next()
            builder.addAddress(prefix.address(), prefix.prefix())
        }

        var hasDefaultV4 = false
        val route4 = options.inet4RouteAddress
        while (route4.hasNext()) {
            val prefix = route4.next()
            if (prefix.prefix() == 0) hasDefaultV4 = true
            builder.addRoute(prefix.address(), prefix.prefix())
        }

        var hasDefaultV6 = false
        val route6 = options.inet6RouteAddress
        while (route6.hasNext()) {
            val prefix = route6.next()
            if (prefix.prefix() == 0) hasDefaultV6 = true
            builder.addRoute(prefix.address(), prefix.prefix())
        }
        if (!hasDefaultV4) builder.addRoute("0.0.0.0", 0)
        if (!hasDefaultV6) builder.addRoute("::", 0)

        runCatching {
            val dns = options.getDNSServerAddress()
            if (dns != null && dns.value.isNotBlank()) builder.addDnsServer(dns.value)
        }.onFailure {
            NativeLog.w("KEQDIS", "app routing: could not read TUN DNS: ${it.message}")
        }
        // Android's system resolver must point at libbox's DNS hijack. Keep
        // the same placeholder convention as the existing VpnService TUN.
        builder.addDnsServer(KeqdisVpnService.TUN_DNS_ADDRESS)

        var includedCount = 0
        runCatching {
            val include = options.includePackage
            while (include.hasNext()) {
                builder.addAllowedApplication(include.next())
                includedCount++
            }
        }.onFailure {
            NativeLog.w("KEQDIS", "app routing: include package filter failed: ${it.message}")
        }
        runCatching {
            val exclude = options.excludePackage
            while (exclude.hasNext()) builder.addDisallowedApplication(exclude.next())
        }.onFailure {
            NativeLog.w("KEQDIS", "app routing: exclude package filter failed: ${it.message}")
        }
        // VpnService must not route its own control traffic back into the TUN.
        // When an allow-list is present, the app is already excluded by default.
        if (includedCount == 0) {
            runCatching { builder.addDisallowedApplication(vpn.packageName) }
        }

        val descriptor = builder.establish()
            ?: throw IllegalStateException("VpnService.Builder.establish() returned null.")
        tunDescriptor = descriptor
        NativeLog.i("KEQDIS", "app routing: libbox TUN established fd=${descriptor.fd}")
        return descriptor.fd
    }

    override fun autoDetectInterfaceControl(fd: Int) {
        if (!vpn.protect(fd)) throw IllegalStateException("protect($fd) failed.")
    }

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q
    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true
    override fun underNetworkExtension(): Boolean = false
    override fun includeAllNetworks(): Boolean = false

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            "Android package owner lookup needs Android 10 or newer."
        }
        val cm = vpn.getSystemService(ConnectivityManager::class.java)
            ?: error("Connectivity service is unavailable.")
        val uid = cm.getConnectionOwnerUid(
            ipProtocol,
            InetSocketAddress(sourceAddress, sourcePort),
            InetSocketAddress(destinationAddress, destinationPort),
        )
        check(uid >= 0) { "Android could not identify the owner of this connection." }
        val packages = vpn.packageManager.getPackagesForUid(uid)?.toList().orEmpty()
        return ConnectionOwner().apply {
            userId = uid
            userName = packages.firstOrNull() ?: ""
            setAndroidPackageNames(StringArray(packages))
        }
    }

    override fun readWIFIState(): WIFIState? = null

    override fun getInterfaces(): NetworkInterfaceIterator? {
        val cm = vpn.getSystemService(ConnectivityManager::class.java) ?: return null
        val javaInterfaces = runCatching {
            Collections.list(NetworkInterface.getNetworkInterfaces())
        }.getOrDefault(emptyList())
        val result = mutableListOf<LibboxNetworkInterface>()

        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) continue
            val link = cm.getLinkProperties(network) ?: continue
            val name = link.interfaceName ?: continue
            val iface = javaInterfaces.firstOrNull { it.name == name } ?: continue
            if (!iface.isUp || iface.isLoopback || iface.isVirtual || name.startsWith("tun")) continue

            val addresses = iface.interfaceAddresses.mapNotNull { address ->
                val value = address.address ?: return@mapNotNull null
                val text = value.hostAddress?.substringBefore('%') ?: return@mapNotNull null
                val bits = if (value is Inet6Address) 128 else if (value is Inet4Address) 32 else return@mapNotNull null
                val prefix = address.networkPrefixLength.toInt()
                if (prefix !in 0..bits) null else "$text/$prefix"
            }
            val kind = when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
                else -> Libbox.InterfaceTypeOther
            }
            val item = LibboxNetworkInterface().apply {
                setName(name)
                setIndex(iface.index)
                setMTU(runCatching { iface.mtu }.getOrDefault(0))
                setType(kind)
                setAddresses(StringArray(addresses))
                setDNSServer(StringArray(link.dnsServers.mapNotNull { it.hostAddress }))
            }
            result.add(item)
        }
        return if (result.isEmpty()) null else NetworkInterfaceArray(result)
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener?) {
        if (listener == null || closed || networkCallback != null) return
        val cm = vpn.getSystemService(ConnectivityManager::class.java) ?: return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = updateDefaultInterface(listener)
            override fun onLost(network: Network) = updateDefaultInterface(listener)
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) =
                updateDefaultInterface(listener)
        }
        networkCallback = cb
        runCatching {
            cm.registerNetworkCallback(
                android.net.NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                    .build(),
                cb,
            )
        }.onFailure {
            networkCallback = null
            NativeLog.w("KEQDIS", "app routing: cannot observe physical interfaces: ${it.message}")
        }
        updateDefaultInterface(listener)
    }

    private fun updateDefaultInterface(listener: InterfaceUpdateListener) {
        if (closed) return
        val cm = vpn.getSystemService(ConnectivityManager::class.java) ?: return
        val javaInterfaces = runCatching {
            Collections.list(NetworkInterface.getNetworkInterfaces())
        }.getOrDefault(emptyList())
        val physical = cm.allNetworks.mapNotNull { network ->
            val caps = cm.getNetworkCapabilities(network) ?: return@mapNotNull null
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) ||
                !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            ) return@mapNotNull null
            val link = cm.getLinkProperties(network) ?: return@mapNotNull null
            val name = link.interfaceName ?: return@mapNotNull null
            val iface = javaInterfaces.firstOrNull { it.name == name } ?: return@mapNotNull null
            val validated = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            val wifi = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
            Triple(network, iface, (if (validated) 1000 else 0) + (if (wifi) 100 else 0))
        }.sortedByDescending { it.third }
        val selected = physical.firstOrNull() ?: return
        runCatching {
            listener.updateDefaultInterface(
                selected.second.name,
                selected.second.index,
                selected.third < 1000,
                false,
            )
        }.onFailure {
            NativeLog.w("KEQDIS", "app routing: default interface update failed: ${it.message}")
        }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener?) {
        val cm = vpn.getSystemService(ConnectivityManager::class.java)
        networkCallback?.let { runCatching { cm?.unregisterNetworkCallback(it) } }
        networkCallback = null
    }

    override fun clearDNSCache() {}
    override fun systemCertificates(): StringIterator? = null
    override fun sendNotification(notification: LibboxNotification?) {}
    override fun localDNSTransport(): LocalDNSTransport? = null
    override fun serviceReload() {
        NativeLog.i("KEQDIS", "app routing: libbox requested a service reload")
    }
    override fun serviceStop() {
        NativeLog.w("KEQDIS", "app routing: libbox service stopped")
    }
    override fun getSystemProxyStatus(): SystemProxyStatus? = null
    override fun setSystemProxyEnabled(enabled: Boolean) {}
    override fun writeDebugMessage(message: String?) {
        if (!message.isNullOrBlank()) NativeLog.d("KEQDIS_LIBBOX", message)
    }

    override fun close() {
        if (closed) return
        closed = true
        val cm = vpn.getSystemService(ConnectivityManager::class.java)
        networkCallback?.let { runCatching { cm?.unregisterNetworkCallback(it) } }
        networkCallback = null
        runCatching { commandServer?.closeService() }
        runCatching { commandServer?.close() }
        commandServer = null
        runCatching { tunDescriptor?.close() }
        tunDescriptor = null
    }

    private class StringArray(private val values: List<String>) : StringIterator {
        private var index = 0
        override fun len(): Int = values.size
        override fun hasNext(): Boolean = index < values.size
        override fun next(): String = values[index++]
    }

    private class NetworkInterfaceArray(
        private val values: List<LibboxNetworkInterface>,
    ) : NetworkInterfaceIterator {
        private var index = 0
        override fun hasNext(): Boolean = index < values.size
        override fun next(): LibboxNetworkInterface = values[index++]
    }

    private companion object {
        private val SETUP_LOCK = Any()
        @Volatile private var boxInitialized = false
    }
}
