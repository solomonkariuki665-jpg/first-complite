import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ---------------------------------------------------------------------------
// CONFIG
// ---------------------------------------------------------------------------
const supabaseUrl = 'https://nhuzmoiciktvavfasico.supabase.co';
const supabaseKey = 'sb_publishable_6Krt4djAO-bGO3sECO_OXw_34KNYS9X';

// Hardcoded demo login. Create this user in Supabase > Authentication > Users.
const demoEmail = 'demo@mamamboga.app';
const demoPassword = 'Solo0717415921@';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseKey);
  runApp(const MyApp());
}

final supabase = Supabase.instance.client;

// ---------------------------------------------------------------------------
// HELPERS
// ---------------------------------------------------------------------------
String cleanError(Object e) {
  if (e is AuthException) return e.message;
  if (e is PostgrestException) return e.message;
  if (e is FunctionException) return 'M-Pesa error: ${e.details}';
  return e.toString();
}

final _numberFormat = NumberFormat('#,##0');
String kes(num n) => 'KES ${_numberFormat.format(n)}';

// 0712345678, +254712345678 or 712345678 -> 254712345678 (null if invalid)
String? normalizePhone(String raw) {
  var p = raw.replaceAll(RegExp(r'[\s+\-]'), '');
  if (p.startsWith('0')) {
    p = '254${p.substring(1)}';
  } else if (RegExp(r'^[17]\d{8}$').hasMatch(p)) {
    p = '254$p';
  }
  return RegExp(r'^254[17]\d{8}$').hasMatch(p) ? p : null;
}

// ---------------------------------------------------------------------------
// APP + SIGN-IN
// ---------------------------------------------------------------------------
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mama Mboga Ledger',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
      home: const SignInGate(),
    );
  }
}

class SignInGate extends StatefulWidget {
  const SignInGate({super.key});

  @override
  State<SignInGate> createState() => _SignInGateState();
}

class _SignInGateState extends State<SignInGate> {
  bool ready = false;
  String? error;

  @override
  void initState() {
    super.initState();
    signIn();
  }

  Future<void> signIn() async {
    try {
      if (supabase.auth.currentSession == null) {
        await supabase.auth.signInWithPassword(
          email: demoEmail,
          password: demoPassword,
        );
      }
      if (mounted) setState(() => ready = true);
    } catch (e) {
      if (mounted) setState(() => error = cleanError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not sign in:\n$error', textAlign: TextAlign.center),
          ),
        ),
      );
    }
    if (!ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return const HomeScreen();
  }
}

// ---------------------------------------------------------------------------
// HOME: who owes Mama
// ---------------------------------------------------------------------------
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Map<String, dynamic>> customers = [];
  bool loading = true;
  String? error;
  RealtimeChannel? channel;

  @override
  void initState() {
    super.initState();
    load();
    // When the M-Pesa callback marks a payment completed, refresh the list.
    channel = supabase
        .channel('ledger-changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'ledger_entries',
          callback: (_) => load(),
        )
        .subscribe();
  }

  @override
  void dispose() {
    if (channel != null) supabase.removeChannel(channel!);
    super.dispose();
  }

  Future<void> load() async {
    try {
      final rows = await supabase
          .from('customer_stats')
          .select()
          .order('balance', ascending: false);
      if (!mounted) return;
      setState(() {
        customers = List<Map<String, dynamic>>.from(rows);
        loading = false;
        error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = cleanError(e);
        loading = false;
      });
    }
  }

  double balanceOf(Map<String, dynamic> c) => (c['balance'] as num).toDouble();

  Future<void> addDebt() async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => AddDebtScreen(customers: customers)),
    );
    if (saved == true) load();
  }

  Future<void> requestPayment(Map<String, dynamic> c) async {
    final controller = TextEditingController(text: balanceOf(c).ceil().toString());
    final amount = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Request payment from ${c['name']}'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'Amount (KES)',
            helperText: 'M-Pesa prompt goes to ${c['phone']}',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(controller.text.trim())),
            child: const Text('Send M-Pesa prompt'),
          ),
        ],
      ),
    );
    if (amount == null || amount < 1 || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await supabase.functions.invoke(
        'stk-push',
        body: {'customer_id': c['id'], 'amount': amount},
      );
      messenger.showSnackBar(SnackBar(
        content: Text('Prompt sent to ${c['phone']}. Waiting for payment...'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(cleanError(e)),
        duration: const Duration(seconds: 12),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalOwed = customers.fold<double>(0, (sum, c) => sum + balanceOf(c));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Who owes Mama'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart),
            tooltip: 'Best customers',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => BestCustomersScreen(customers: customers),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: addDebt,
        icon: const Icon(Icons.add),
        label: const Text('Add debt'),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(error!)))
              : RefreshIndicator(
                  onRefresh: load,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 96),
                    children: [
                      Card(
                        margin: const EdgeInsets.all(16),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Total owed to you'),
                              const SizedBox(height: 4),
                              Text(
                                kes(totalOwed),
                                style: Theme.of(context).textTheme.headlineMedium,
                              ),
                            ],
                          ),
                        ),
                      ),
                      for (final c in customers)
                        ListTile(
                          title: Text(c['name'] as String),
                          subtitle: Text(
                            balanceOf(c) > 0 ? 'Owes ${kes(balanceOf(c))}' : 'All paid',
                          ),
                          trailing: balanceOf(c) > 0
                              ? FilledButton.tonal(
                                  onPressed: () => requestPayment(c),
                                  child: const Text('Request payment'),
                                )
                              : const Icon(Icons.check_circle, color: Colors.green),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => CustomerLedgerScreen(customer: c),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }
}

// ---------------------------------------------------------------------------
// ADD DEBT
// ---------------------------------------------------------------------------
class AddDebtScreen extends StatefulWidget {
  const AddDebtScreen({super.key, required this.customers});

  final List<Map<String, dynamic>> customers;

  @override
  State<AddDebtScreen> createState() => _AddDebtScreenState();
}

class _AddDebtScreenState extends State<AddDebtScreen> {
  final phoneController = TextEditingController();
  final amountController = TextEditingController();
  final itemController = TextEditingController();
  String name = '';
  bool busy = false;

  // The existing customer matching the typed name, if any.
  Map<String, dynamic>? get existing {
    final typed = name.trim().toLowerCase();
    for (final c in widget.customers) {
      if ((c['name'] as String).toLowerCase() == typed) return c;
    }
    return null;
  }

  void toast(String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  Future<void> save() async {
    final typedName = name.trim();
    final amount = int.tryParse(amountController.text.trim());
    final item = itemController.text.trim();

    if (typedName.isEmpty) {
      toast('Enter the customer name');
      return;
    }
    if (amount == null || amount < 1) {
      toast('Enter the amount in whole shillings');
      return;
    }

    setState(() => busy = true);
    try {
      String customerId;
      final match = existing;
      if (match != null) {
        customerId = match['id'] as String;
      } else {
        final phone = normalizePhone(phoneController.text);
        if (phone == null) {
          setState(() => busy = false);
          toast('Enter a valid Safaricom number, e.g. 0712345678');
          return;
        }
        final row = await supabase
            .from('customers')
            .insert({'name': typedName, 'phone': phone})
            .select('id')
            .single();
        customerId = row['id'] as String;
      }

      await supabase.from('ledger_entries').insert({
        'customer_id': customerId,
        'type': 'debt',
        'amount': amount,
        'item': item.isEmpty ? null : item,
      });

      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => busy = false);
        toast('Could not save: ${cleanError(e)}');
      }
    }
  }

  @override
  void dispose() {
    phoneController.dispose();
    amountController.dispose();
    itemController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = name.trim().isNotEmpty && existing == null;

    return Scaffold(
      appBar: AppBar(title: const Text('Add debt')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Autocomplete<String>(
            optionsBuilder: (value) => widget.customers
                .map((c) => c['name'] as String)
                .where((n) => n.toLowerCase().contains(value.text.toLowerCase())),
            onSelected: (selected) => setState(() => name = selected),
            fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
              return TextField(
                controller: controller,
                focusNode: focusNode,
                decoration: const InputDecoration(
                  labelText: 'Customer name',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => name = v),
              );
            },
          ),
          if (isNew) ...[
            const SizedBox(height: 16),
            TextField(
              controller: phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'New customer: M-Pesa phone number',
                hintText: '0712345678',
                border: OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: amountController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Amount (KES)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: itemController,
            decoration: const InputDecoration(
              labelText: 'What did they take? (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: busy ? null : save,
            child: Text(busy ? 'Saving...' : 'Save debt'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// BEST CUSTOMERS: chart + loyalty + "usually pays in X days"
// ---------------------------------------------------------------------------
class BestCustomersScreen extends StatelessWidget {
  const BestCustomersScreen({super.key, required this.customers});

  final List<Map<String, dynamic>> customers;

  double spent(Map<String, dynamic> c) => (c['total_spent'] as num).toDouble();
  int visits(Map<String, dynamic> c) => (c['visits'] as num).toInt();

  @override
  Widget build(BuildContext context) {
    final sorted = [...customers]..sort((a, b) => spent(b).compareTo(spent(a)));
    final top = sorted.take(6).toList();
    final maxY = top.isEmpty ? 100.0 : spent(top.first) * 1.2;
    final green = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(title: const Text('Best customers')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Total spent on credit', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          SizedBox(
            height: 240,
            child: top.isEmpty
                ? const Center(child: Text('No customers yet'))
                : BarChart(
                    BarChartData(
                      maxY: maxY,
                      alignment: BarChartAlignment.spaceAround,
                      gridData: const FlGridData(show: false),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 32,
                            getTitlesWidget: (value, meta) {
                              final i = value.toInt();
                              if (i < 0 || i >= top.length) return const SizedBox.shrink();
                              return Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  (top[i]['name'] as String).split(' ').first,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      barTouchData: BarTouchData(
                        touchTooltipData: BarTouchTooltipData(
                          getTooltipItem: (group, groupIndex, rod, rodIndex) => BarTooltipItem(
                            '${top[groupIndex]['name']}\n${kes(rod.toY)}',
                            const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                      barGroups: [
                        for (var i = 0; i < top.length; i++)
                          BarChartGroupData(
                            x: i,
                            barRods: [
                              BarChartRodData(
                                toY: spent(top[i]),
                                width: 22,
                                color: green,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 24),
          Text('Loyalty and trust', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final c in sorted)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Row(
                children: [
                  Flexible(child: Text(c['name'] as String)),
                  if (visits(c) >= 5) ...[
                    const SizedBox(width: 8),
                    const Chip(
                      label: Text('Loyal'),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ],
              ),
              subtitle: Text(
                '${visits(c)} visits, ${kes(spent(c))} spent'
                '${c['avg_days_to_pay'] != null ? '\nUsually pays in ${c['avg_days_to_pay']} days' : '\nNo payments yet'}',
              ),
              isThreeLine: true,
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CUSTOMER LEDGER: every debt and payment, newest first
// ---------------------------------------------------------------------------
class CustomerLedgerScreen extends StatelessWidget {
  const CustomerLedgerScreen({super.key, required this.customer});

  final Map<String, dynamic> customer;

  Future<List<Map<String, dynamic>>> load() async {
    final rows = await supabase
        .from('ledger_entries')
        .select()
        .eq('customer_id', customer['id'])
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(rows);
  }

  @override
  Widget build(BuildContext context) {
    final balance = (customer['balance'] as num).toDouble();

    return Scaffold(
      appBar: AppBar(title: Text(customer['name'] as String)),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: load(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text(cleanError(snapshot.error!)));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = snapshot.data!;
          return ListView(
            children: [
              ListTile(
                title: const Text('Balance'),
                trailing: Text(
                  kes(balance),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const Divider(height: 1),
              for (final e in entries) EntryTile(entry: e),
            ],
          );
        },
      ),
    );
  }
}

class EntryTile extends StatelessWidget {
  const EntryTile({super.key, required this.entry});

  final Map<String, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final isDebt = entry['type'] == 'debt';
    final status = entry['status'] as String;
    final amount = (entry['amount'] as num).toDouble();
    final when = DateFormat('d MMM, HH:mm')
        .format(DateTime.parse(entry['created_at'] as String).toLocal());

    final title = isDebt
        ? (entry['item'] as String?) ?? 'Debt'
        : 'M-Pesa payment${entry['mpesa_receipt'] != null ? ' (${entry['mpesa_receipt']})' : ''}';
    final statusNote = status == 'pending'
        ? ' - waiting for customer'
        : status == 'failed'
            ? ' - failed'
            : '';

    return ListTile(
      leading: Icon(
        isDebt ? Icons.arrow_upward : Icons.arrow_downward,
        color: isDebt ? Colors.red : Colors.green,
      ),
      title: Text(title),
      subtitle: Text('$when$statusNote'),
      trailing: Text(
        '${isDebt ? '+' : '-'}${kes(amount)}',
        style: TextStyle(
          color: status == 'completed' ? (isDebt ? Colors.red : Colors.green) : Colors.grey,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}