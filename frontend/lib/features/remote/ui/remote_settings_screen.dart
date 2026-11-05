import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../data/host_link.dart';
import '../data/relay_client.dart';
import '../data/remote_api.dart';
import '../data/remote_store.dart';
import '../domain/remote_crypto.dart';
import '../domain/remote_protocol.dart';
import '../remote_providers.dart';
import 'qr_scanner.dart';

/// Settings → Remote coding. On a desktop: host Code sessions for the
/// account's other devices (pairing code + QR, approvals, paired devices).
/// Everywhere: pair with a host by scanning its QR or typing its code.
class RemoteSettingsBody extends ConsumerWidget {
  const RemoteSettingsBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 32),
      // A computer hosts its sessions; other devices pair with one to follow them.
      children: [if (Host.isDesktop) const _HostSection() else const _PairedHostsSection()],
    );
  }
}

String _countdown(Duration d) {
  if (d.isNegative) return 'expired';
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

// ------------------------------------------------------------------ host

class _HostSection extends ConsumerStatefulWidget {
  const _HostSection();

  @override
  ConsumerState<_HostSection> createState() => _HostSectionState();
}

class _HostSectionState extends ConsumerState<_HostSection> {
  ({PairingCode code, String qr})? _code;
  List<RemoteDevice>? _devices;
  bool _busy = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_code != null && mounted) setState(() {});
    });
    unawaited(_loadDevices());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    try {
      final devices = await ref.read(remoteHostingProvider.notifier).devices();
      if (mounted) setState(() => _devices = devices);
    } on Object {
      if (mounted) setState(() => _devices = const []);
    }
  }

  Future<void> _run(Future<void> Function() action, String failure) async {
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (e) {
      if (mounted) showAdaptiveToast(context, '$failure: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(bool on) => _run(() async {
    final hosting = ref.read(remoteHostingProvider.notifier);
    if (on) {
      await hosting.enable();
    } else {
      await hosting.disable();
      _code = null;
    }
  }, on ? "Couldn't turn hosting on" : "Couldn't turn hosting off");

  Future<void> _newCode() => _run(() async {
    final code = await ref.read(remoteHostingProvider.notifier).newCode();
    if (mounted) setState(() => _code = code);
  }, "Couldn't make a pairing code");

  Future<void> _decide(PairRequest r, bool approve) => _run(() async {
    await ref.read(remoteHostingProvider.notifier).decide(r, approve: approve);
    if (approve) _code = null;
    await _loadDevices();
  }, "Couldn't record the decision");

  Future<void> _revoke(RemoteDevice d) async {
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Remove ${d.name}?',
      message: 'It loses access to Code on this computer at once. It can pair again with a new code.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok) return;
    await _run(() async {
      await ref.read(remoteHostingProvider.notifier).revokeDevice(d.id);
      await _loadDevices();
    }, "Couldn't remove the device");
  }

  Future<void> _forget() async {
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Stop hosting for good?',
      message: 'This computer is removed from your account and every paired device loses it.',
      confirmLabel: 'Remove host',
      destructive: true,
    );
    if (!ok) return;
    await _run(() async {
      await ref.read(remoteHostingProvider.notifier).forget();
      _code = null;
      _devices = const [];
    }, "Couldn't remove this host");
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final hosting = ref.watch(remoteHostingProvider);
    final link = hosting.link;
    final connected = {for (final c in link.clients) c.deviceId};
    final status = !hosting.enabled
        ? 'Off. Your other devices can\'t reach this computer.'
        : link.revoked
        ? 'This host was removed from your account.'
        : link.replaced
        ? 'Another copy of EveryAI took over hosting.'
        : link.connected
        ? 'Online${link.clients.isEmpty ? '' : ', ${link.clients.length} connected'}'
        : 'Connecting to the relay…';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AdaptiveSectionHeader('This computer'),
        AdaptiveListTile(
          title: const Text('Host Code sessions'),
          subtitle: Text(status),
          trailing: AdaptiveSwitch(value: hosting.enabled, onChanged: _busy || !hosting.loaded ? null : _toggle),
        ),
        if (hosting.enabled) ...[
          AdaptiveListTile(
            title: const Text('Security code'),
            subtitle: Text(
              '${hosting.fingerprint}\nDevices check this when they pair. Messages are encrypted end to end; '
              'the server only relays them.',
            ),
          ),
          for (final r in link.pending) _PairRequestCard(request: r, busy: _busy, onDecide: _decide),
          if (_code case final code?)
            _PairingCodeCard(code: code.code, qr: code.qr, fingerprint: hosting.fingerprint)
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: AdaptiveButton(label: 'Pair a device', busy: _busy, onPressed: _newCode),
              ),
            ),
        ],
        if (hosting.host != null) ...[
          const AdaptiveSectionHeader('Paired devices'),
          if (_devices == null)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: AdaptiveProgress()),
            )
          else if (_devices!.isEmpty)
            AdaptiveListTile(title: Text('No devices yet', style: theme.type.body.tint(theme.textMuted)))
          else
            for (final d in _devices!)
              AdaptiveListTile(
                title: Text(d.name),
                subtitle: Text(
                  connected.contains(d.id)
                      ? 'Connected now'
                      : d.lastSeen == null
                      ? 'Not connected yet'
                      : 'Last seen ${_date(d.lastSeen!)}',
                ),
                trailing: AdaptiveButton(
                  label: 'Remove',
                  emphasis: ButtonEmphasis.plain,
                  onPressed: _busy ? null : () => _revoke(d),
                ),
              ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: AdaptiveButton(
                label: 'Remove this host',
                emphasis: ButtonEmphasis.plain,
                onPressed: _busy ? null : _forget,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

String _date(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

class _PairingCodeCard extends StatelessWidget {
  const _PairingCodeCard({required this.code, required this.qr, required this.fingerprint});

  final PairingCode code;
  final String qr;
  final String fingerprint;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final left = code.expiresAt.difference(DateTime.now());
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.surface,
        borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
        border: Border.all(color: theme.border),
      ),
      child: Wrap(
        spacing: 20,
        runSpacing: 16,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: const Color(0xFFFFFFFF), borderRadius: BorderRadius.circular(12)),
            child: QrImageView(data: qr, size: 176, backgroundColor: const Color(0xFFFFFFFF)),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Scan with your phone', style: theme.type.headline.tint(theme.text)),
                const SizedBox(height: 6),
                Text(
                  'In EveryAI on the other device, open Settings → Remote coding and scan this code, or type it:',
                  style: theme.type.callout.copyWith(color: theme.textMuted, height: 1.4),
                ),
                const SizedBox(height: 10),
                Text(
                  displayCode(code.code),
                  style: theme.type.largeTitle.mono.copyWith(color: theme.text, letterSpacing: 3),
                ),
                const SizedBox(height: 6),
                Text(
                  left.isNegative ? 'Expired. Make a new code.' : 'Single use, expires in ${_countdown(left)}',
                  style: theme.type.caption.tint(theme.textMuted),
                ),
                const SizedBox(height: 4),
                Text('Security code: $fingerprint', style: theme.type.caption.mono.tint(theme.textMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PairRequestCard extends StatelessWidget {
  const _PairRequestCard({required this.request, required this.busy, required this.onDecide});

  final PairRequest request;
  final bool busy;
  final void Function(PairRequest, bool approve) onDecide;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final left = request.decideBy.difference(DateTime.now());
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.accent.withValues(alpha: theme.isDark ? 0.16 : 0.08),
        borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${request.deviceName} wants to use Code on this computer', style: theme.type.headline.tint(theme.text)),
          const SizedBox(height: 6),
          Text(
            'Approve only if that device shows this security code: ${request.fingerprint}'
            '${left.isNegative ? '' : ' (${_countdown(left)} left)'}',
            style: theme.type.callout.copyWith(color: theme.textMuted, height: 1.4),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              AdaptiveButton(label: 'Approve', onPressed: busy ? null : () => onDecide(request, true)),
              AdaptiveButton(
                label: 'Deny',
                emphasis: ButtonEmphasis.secondary,
                onPressed: busy ? null : () => onDecide(request, false),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ device

class _PairedHostsSection extends ConsumerStatefulWidget {
  const _PairedHostsSection();

  @override
  ConsumerState<_PairedHostsSection> createState() => _PairedHostsSectionState();
}

class _PairedHostsSectionState extends ConsumerState<_PairedHostsSection> {
  final _code = TextEditingController();
  bool _scanning = false;
  bool _busy = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_pollPending()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _code.dispose();
    super.dispose();
  }

  bool _polling = false;

  /// Asks about pairings still waiting for the host.
  Future<void> _pollPending() async {
    if (_polling) return;
    final waiting = (ref.read(pairedHostsProvider).value ?? const <PairedHost>[]).where((h) => !h.approved);
    if (waiting.isEmpty) return;
    _polling = true;
    try {
      for (final h in waiting) {
        final status = await ref.read(pairedHostsProvider.notifier).poll(h);
        if (!mounted) return;
        switch (status) {
          case 'approved':
            showAdaptiveToast(context, 'Paired with ${h.name}. Code is in the sidebar.');
          case 'denied':
            showAdaptiveToast(context, '${h.name} declined the pairing.');
          case 'expired':
            showAdaptiveToast(context, 'The pairing with ${h.name} expired. Try a new code.');
        }
      }
    } on Object {
      // Offline: try again on the next tick.
    } finally {
      _polling = false;
    }
  }

  Future<void> _pair(String text) async {
    final payload = PairingPayload.parse(text);
    if (payload == null) {
      showAdaptiveToast(context, 'That isn\'t a pairing code. It looks like ABCD-EFGH.');
      return;
    }
    setState(() {
      _busy = true;
      _scanning = false;
    });
    try {
      final host = await ref.read(pairedHostsProvider.notifier).redeem(payload);
      _code.clear();
      if (mounted) showAdaptiveToast(context, 'Approve this device on ${host.name} to finish.');
    } on Object catch (e) {
      if (mounted) showAdaptiveToast(context, "Couldn't pair: $e");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unpair(PairedHost h) async {
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Unpair ${h.name}?',
      message: 'Code sessions on it stay there, but this device can no longer reach them.',
      confirmLabel: 'Unpair',
      destructive: true,
    );
    if (ok) await ref.read(pairedHostsProvider.notifier).unpair(h.hostId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final hosts = ref.watch(pairedHostsProvider).value ?? const <PairedHost>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AdaptiveSectionHeader('Computers this device uses'),
        if (hosts.isEmpty)
          AdaptiveListTile(
            title: Text(
              Host.isDesktop ? 'None. Pair to use another computer\'s Code sessions.' : 'None yet',
              style: theme.type.body.tint(theme.textMuted),
            ),
          ),
        for (final h in hosts) _PairedHostTile(host: h, onUnpair: () => _unpair(h)),
        const AdaptiveSectionHeader('Pair with a computer'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Text(
            'On the computer, open Settings → Remote coding, turn on hosting and choose Pair a device.',
            style: theme.type.callout.copyWith(color: theme.textMuted, height: 1.4),
          ),
        ),
        if (Host.isMobile) ...[
          if (_scanning)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(
                height: 300,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
                  child: QrScanner(onScanned: _pair),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: AdaptiveButton(
                label: _scanning ? 'Stop scanning' : 'Scan QR code',
                emphasis: _scanning ? ButtonEmphasis.secondary : ButtonEmphasis.primary,
                onPressed: _busy ? null : () => setState(() => _scanning = !_scanning),
              ),
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: AdaptiveTextField(
                  controller: _code,
                  placeholder: 'Pairing code (ABCD-EFGH)',
                  textInputAction: TextInputAction.go,
                  onSubmitted: _busy ? null : _pair,
                ),
              ),
              const SizedBox(width: 8),
              AdaptiveButton(
                label: 'Pair',
                emphasis: ButtonEmphasis.secondary,
                busy: _busy,
                onPressed: () => _pair(_code.text),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PairedHostTile extends ConsumerWidget {
  const _PairedHostTile({required this.host, required this.onUnpair});

  final PairedHost host;
  final VoidCallback onUnpair;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = host.approved
        ? switch (ref.watch(remoteLinkStatusProvider(host.hostId))) {
            AsyncData(:final value) => value.label,
            AsyncError(:final error) => '$error',
            _ => RemoteLinkStatus.connecting.label,
          }
        : null;
    return AdaptiveListTile(
      title: Text(host.name.isEmpty ? 'Computer' : host.name),
      subtitle: host.approved
          ? Text(status!)
          : FutureBuilder<String>(
              future: _deviceFingerprint(host),
              builder: (context, snap) =>
                  Text('Waiting for approval on the computer. It should show this security code: ${snap.data ?? '…'}'),
            ),
      trailing: AdaptiveButton(
        label: host.approved ? 'Unpair' : 'Cancel',
        emphasis: ButtonEmphasis.plain,
        onPressed: onUnpair,
      ),
    );
  }

  static Future<String> _deviceFingerprint(PairedHost host) async =>
      keyFingerprint((await RemoteIdentity.restore(host.privateKey)).publicKey);
}
