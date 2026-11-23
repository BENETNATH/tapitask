import "package:material_ui/material_ui.dart";

import "../data/database.dart";
import "../l10n/s.dart";
import "../state/app_state.dart";
import "task_details.dart";

enum _CalendarView {
  day(1),
  twoDays(2),
  threeDays(3),
  fourDays(4),
  week(7),
  month(0);

  const _CalendarView(this.days);
  final int days;

  String get label => switch (this) {
        day => S.calendarDay,
        week => S.calendarWeek,
        month => S.calendarMonth,
        _ => S.calendarDays(days),
      };
}

typedef _CalendarTask = ({LocalItem item, String listTitle});
typedef _CalendarRange = ({DateTime start, DateTime end});

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key, required this.state});

  final AppState state;

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  _CalendarView _view = _CalendarView.week;
  DateTime _selected = DateUtils.dateOnly(DateTime.now());
  bool _planned = true;
  bool _completed = true;
  late int _firstWeekday;
  _CalendarRange? _range;
  late Stream<List<_CalendarTask>> _tasks;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _firstWeekday = MaterialLocalizations.of(context).firstDayOfWeekIndex;
    _updateRange();
  }

  DateTime _addDays(DateTime day, int days) =>
      DateTime(day.year, day.month, day.day + days);

  int _weekdayOffset(DateTime day) => (day.weekday % 7 - _firstWeekday + 7) % 7;

  void _updateRange() {
    final start = switch (_view) {
      _CalendarView.month => DateTime(_selected.year, _selected.month),
      _CalendarView.week => _addDays(_selected, -_weekdayOffset(_selected)),
      _ => _selected,
    };
    final end = _view == _CalendarView.month
        ? DateTime(start.year, start.month + 1)
        : _addDays(start, _view.days);
    final range = (start: start, end: end);
    if (range == _range) return;
    _range = range;
    _tasks = widget.state.db.watchCalendarItems(start, end);
  }

  void _select(DateTime day) => setState(() {
        _selected = DateUtils.dateOnly(day);
        _updateRange();
      });

  void _move(int direction) {
    final start = _range!.start;
    _select(_view == _CalendarView.month
        ? DateTime(start.year, start.month + direction)
        : _addDays(start, _view.days * direction));
  }

  Future<void> _chooseDate() async {
    final initial = _selected;
    final now = DateTime.now();
    final first = DateTime(now.year - 100);
    final last = DateTime(now.year + 100, 12, 31);
    final day = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: initial.isBefore(first) ? initial : first,
      lastDate: initial.isAfter(last) ? initial : last,
    );
    if (mounted && day != null) _select(day);
  }

  DateTime? _eventDate(LocalItem item) =>
      item.done ? item.completedAt?.toLocal() ?? item.localDue : item.localDue;

  @override
  Widget build(BuildContext context) {
    final local = MaterialLocalizations.of(context);
    final range = _range!;
    final periodLabel = switch (_view) {
      _CalendarView.month => local.formatMonthYear(range.start),
      _CalendarView.day => local.formatMediumDate(range.start),
      _ => "${local.formatShortMonthDay(range.start)} – "
          "${local.formatShortMonthDay(_addDays(range.end, -1))}",
    };
    return Scaffold(
      appBar: AppBar(title: Text(S.calendar)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: S.calendarPrevious,
                  onPressed: () => _move(-1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Tooltip(
                    message: S.calendarChooseDate,
                    child: TextButton(
                      onPressed: _chooseDate,
                      child: Text(periodLabel, textAlign: TextAlign.center),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: S.calendarNext,
                  onPressed: () => _move(1),
                  icon: const Icon(Icons.chevron_right),
                ),
                IconButton(
                  tooltip: S.today,
                  onPressed: () => _select(DateTime.now()),
                  icon: const Icon(Icons.today_outlined),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Semantics(
                  label: S.calendarView,
                  child: DropdownButton<_CalendarView>(
                    key: const ValueKey("calendar-view"),
                    value: _view,
                    items: [
                      for (final view in _CalendarView.values)
                        DropdownMenuItem(value: view, child: Text(view.label)),
                    ],
                    onChanged: (view) {
                      if (view == null) return;
                      setState(() {
                        _view = view;
                        _updateRange();
                      });
                    },
                  ),
                ),
                FilterChip(
                  label: Text(S.calendarPlanned),
                  selected: _planned,
                  onSelected: (value) => setState(() => _planned = value),
                ),
                FilterChip(
                  label: Text(S.completedTasks),
                  selected: _completed,
                  onSelected: (value) => setState(() => _completed = value),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: StreamBuilder<List<_CalendarTask>>(
              key: ValueKey(range),
              stream: _tasks,
              builder: (context, snapshot) {
                final groups = <DateTime, List<_CalendarTask>>{};
                for (final task in snapshot.data ?? const <_CalendarTask>[]) {
                  if (task.item.done ? !_completed : !_planned) continue;
                  final date = _eventDate(task.item);
                  if (date == null) continue;
                  groups
                      .putIfAbsent(DateUtils.dateOnly(date), () => [])
                      .add(task);
                }
                for (final tasks in groups.values) {
                  tasks.sort((a, b) {
                    if (a.item.done != b.item.done) return a.item.done ? 1 : -1;
                    return _eventDate(a.item)!.compareTo(_eventDate(b.item)!);
                  });
                }
                final days = _view == _CalendarView.month
                    ? [_selected]
                    : [
                        for (var day = range.start;
                            day.isBefore(range.end);
                            day = _addDays(day, 1))
                          day,
                      ];
                return CustomScrollView(
                  key: ValueKey((range, _view)),
                  slivers: [
                    if (_view == _CalendarView.month)
                      SliverToBoxAdapter(child: _monthGrid(range, groups)),
                    for (final day in days) ..._agenda(day, groups[day] ?? []),
                    if (groups.isEmpty && days.length > 1)
                      SliverToBoxAdapter(child: _emptyDay()),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyDay() => Padding(
        padding: const EdgeInsets.all(20),
        child: Center(child: Text(S.calendarEmpty)),
      );

  List<Widget> _agenda(DateTime day, List<_CalendarTask> tasks) {
    final local = MaterialLocalizations.of(context);
    final theme = Theme.of(context);
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Text(local.formatFullDate(day),
              style: theme.textTheme.titleSmall),
        ),
      ),
      if (tasks.isEmpty &&
          (_view == _CalendarView.day || _view == _CalendarView.month))
        SliverToBoxAdapter(child: _emptyDay()),
      SliverList.builder(
        itemCount: tasks.length,
        itemBuilder: (context, index) {
          final task = tasks[index];
          final item = task.item;
          final time = item.done ? item.completedAt != null : item.dueDay == null;
          final timeLabel = time
              ? TimeOfDay.fromDateTime(_eventDate(item)!).format(context)
              : item.done
                  ? null
                  : S.allDay;
          return TaskTile(
            state: widget.state,
            item: item,
            dense: true,
            title: Text(item.label,
                style: TextStyle(
                  color: item.done ? theme.colorScheme.onSurfaceVariant : null,
                  decoration: item.done ? TextDecoration.lineThrough : null,
                )),
            subtitle: Text(
                [task.listTitle, if (timeLabel != null) timeLabel].join(" · ")),
          );
        },
      ),
    ];
  }

  Widget _monthGrid(
      _CalendarRange range, Map<DateTime, List<_CalendarTask>> groups) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final weekdays = MaterialLocalizations.of(context).narrowWeekdays;
    final offset = _weekdayOffset(range.start);
    final dayCount =
        DateUtils.getDaysInMonth(range.start.year, range.start.month);
    final cells = ((offset + dayCount + 6) ~/ 7) * 7;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          Row(children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                  child:
                      Center(child: Text(weekdays[(_firstWeekday + i) % 7]))),
          ]),
          const SizedBox(height: 6),
          LayoutBuilder(builder: (context, constraints) {
            final roomy = constraints.maxWidth >= 600;
            final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
            return GridView.builder(
              itemCount: cells,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                crossAxisSpacing: 3,
                mainAxisSpacing: 3,
                mainAxisExtent: (roomy ? 66.0 : 44.0) * textScale.clamp(1, 3),
              ),
              itemBuilder: (context, index) {
                final number = index - offset + 1;
                if (number < 1 || number > dayCount) {
                  return const SizedBox.shrink();
                }
                final day =
                    DateTime(range.start.year, range.start.month, number);
                final tasks = groups[day] ?? const <_CalendarTask>[];
                final selected = day == _selected;
                final inMonthToday = DateUtils.isSameDay(day, DateTime.now());
                return Semantics(
                  selected: selected,
                  button: true,
                  label: MaterialLocalizations.of(context).formatFullDate(day),
                  child: Material(
                    color: selected
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _select(day),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 3),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("$number",
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: inMonthToday ? scheme.primary : null,
                                  fontWeight:
                                      inMonthToday ? FontWeight.bold : null,
                                )),
                            if (roomy)
                              for (final task in tasks.take(2))
                                Text(task.item.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      decoration: task.item.done
                                          ? TextDecoration.lineThrough
                                          : null,
                                    )),
                            if (!roomy && tasks.isNotEmpty)
                              Text("${tasks.length}",
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall
                                      ?.copyWith(color: scheme.primary)),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          }),
        ],
      ),
    );
  }
}
