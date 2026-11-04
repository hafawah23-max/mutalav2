import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

const forest = Color(0xFF123F35);
const gold = Color(0xFFC69D50);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Reminders.init();
  runApp(const MutalaApp());
}

class Book {
  String id, title, author, filePath;
  int pages, currentPage, planDays, reminderHour, reminderMinute;
  DateTime started;
  Book({required this.id, required this.title, required this.author,
    required this.filePath, this.pages = 0, this.currentPage = 0,
    this.planDays = 0, this.reminderHour = 20, this.reminderMinute = 0,
    required this.started});
  bool get finished => pages > 0 && currentPage >= pages;
  int get dailyTarget => planDays <= 0 || pages <= 0 ? 0 : (pages / planDays).ceil();
  int get daysElapsed => DateTime.now().difference(DateTime(started.year,started.month,started.day)).inDays + 1;
  Map<String,dynamic> toJson() => {
    'id':id,'title':title,'author':author,'filePath':filePath,'pages':pages,
    'currentPage':currentPage,'planDays':planDays,'reminderHour':reminderHour,
    'reminderMinute':reminderMinute,'started':started.toIso8601String()};
  factory Book.fromJson(Map<String,dynamic> x) => Book(
    id:x['id'] as String,title:x['title'] as String,author:x['author'] as String? ?? '',
    filePath:x['filePath'] as String,pages:x['pages'] as int? ?? 0,
    currentPage:x['currentPage'] as int? ?? 0,planDays:x['planDays'] as int? ?? 0,
    reminderHour:x['reminderHour'] as int? ?? 20,
    reminderMinute:x['reminderMinute'] as int? ?? 0,
    started:DateTime.tryParse(x['started'] as String? ?? '') ?? DateTime.now());
}

class BookStore {
  static const key = 'mutala_books_v1';
  static Future<List<Book>> load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final raw = jsonDecode(prefs.getString(key) ?? '[]') as List;
      return raw.map((x)=>Book.fromJson(Map<String,dynamic>.from(x as Map))).toList();
    } catch (_) {return [];}
  }
  static Future<void> save(List<Book> books) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key,jsonEncode(books.map((b)=>b.toJson()).toList()));
  }
}

class Reminders {
  static final plugin = FlutterLocalNotificationsPlugin();
  static Future<void> init() async {
    tz.initializeTimeZones();
    try { tz.setLocalLocation(tz.getLocation(await FlutterTimezone.getLocalTimezone())); }
    catch (_) { tz.setLocalLocation(tz.UTC); }
    const settings = InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher'));
    await plugin.initialize(settings);
  }
  static Future<void> schedule(Book book) async {
    if (book.planDays <= 0) return;
    final android = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    final now = tz.TZDateTime.now(tz.local);
    var next = tz.TZDateTime(tz.local,now.year,now.month,now.day,book.reminderHour,book.reminderMinute);
    if (!next.isAfter(now)) next = next.add(const Duration(days:1));
    await plugin.zonedSchedule(
      (int.tryParse(book.id) ?? 0) % 2147483647, 'مُطَلعٌ | موعد القراءة 📖',
      'رحلتك مع «${book.title}» تنتظرك. اقرأ ${book.dailyTarget} صفحة اليوم!',
      next,
      const NotificationDetails(android: AndroidNotificationDetails(
        'daily_reading','تذكيرات القراءة',channelDescription:'تذكير يومي بخطة القراءة',
        importance:Importance.high,priority:Priority.high)),
      androidScheduleMode:AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents:DateTimeComponents.time);
  }
  static Future<void> cancel(Book book) => plugin.cancel((int.tryParse(book.id) ?? 0) % 2147483647);
}

class MutalaApp extends StatelessWidget {
  const MutalaApp({super.key});
  @override Widget build(BuildContext context) => MaterialApp(
    title:'مُطَلعٌ | رفيق القراءة',debugShowCheckedModeBanner:false,
    locale:const Locale('ar'),
    theme:ThemeData(useMaterial3:true,colorScheme:ColorScheme.fromSeed(seedColor:forest),
      scaffoldBackgroundColor:const Color(0xFFF7F5EF),appBarTheme:const AppBarTheme(
        backgroundColor:Color(0xFFF7F5EF),centerTitle:true)),
    builder:(context,child)=>Directionality(textDirection:TextDirection.rtl,child:child!),
    home:const LibraryScreen());
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});
  @override State<LibraryScreen> createState()=>_LibraryScreenState();
}
class _LibraryScreenState extends State<LibraryScreen> {
  List<Book> books=[];
  int tab=0;
  @override void initState(){super.initState();refresh();}
  Future<void> refresh() async {final loaded=await BookStore.load();if(mounted)setState(()=>books=loaded);}
  Future<void> addBook() async {
    final result=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['pdf']);
    if(result==null || result.files.single.path==null)return;
    final source=File(result.files.single.path!);
    final dir=Directory(path.join((await getApplicationDocumentsDirectory()).path,'books'));
    await dir.create(recursive:true);
    final id=DateTime.now().microsecondsSinceEpoch.toString();
    final destination=path.join(dir.path,'$id.pdf');
    await source.copy(destination);
    if(!mounted)return;
    final title=path.basenameWithoutExtension(result.files.single.name);
    final book=Book(id:id,title:title,author:'',filePath:destination,started:DateTime.now());
    final accepted=await Navigator.push<bool>(context,MaterialPageRoute(builder:(_)=>BookSetup(book:book,isNew:true)));
    if(accepted==true){books.insert(0,book);await BookStore.save(books);await Reminders.schedule(book);await refresh();}
    else {try{await File(destination).delete();}catch(_){}}
  }
  Future<void> openBook(Book b) async {
    if(!await File(b.filePath).exists()){
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('ملف الكتاب غير موجود على الجهاز')));
      return;
    }
    if(!mounted)return;
    await Navigator.push(context,MaterialPageRoute(builder:(_)=>ReaderScreen(book:b,onSaved:() async {
      await BookStore.save(books);if(mounted)setState((){});
    })));
    await BookStore.save(books);if(mounted)setState((){});
  }
  Future<void> editBook(Book b) async {
    final ok=await Navigator.push<bool>(context,MaterialPageRoute(builder:(_)=>BookSetup(book:b,isNew:false)));
    if(ok==true){await BookStore.save(books);await Reminders.cancel(b);if(!b.finished)await Reminders.schedule(b);setState((){});}
  }
  Future<void> removeBook(Book b) async {
    final yes=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(
      title:const Text('حذف الكتاب؟'),content:const Text('سيُحذف الكتاب ونسخته المحفوظة من داخل التطبيق.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('إلغاء')),
        TextButton(onPressed:()=>Navigator.pop(c,true),child:const Text('حذف'))]));
    if(yes!=true)return;
    await Reminders.cancel(b);books.remove(b);await BookStore.save(books);
    try{await File(b.filePath).delete();}catch(_){}
    setState((){});
  }
  @override Widget build(BuildContext context){
    final shown=books.where((b)=>tab==0 || (tab==1 && !b.finished) || (tab==2 && b.finished)).toList();
    final completed=books.where((b)=>b.finished).length;
    final pagesRead=books.fold<int>(0,(s,b)=>s+b.currentPage);
    return Scaffold(
      appBar:AppBar(title:const Text('مُطَلعٌ  |  رفيق القراءة',style:TextStyle(fontWeight:FontWeight.bold,color:forest))),
      floatingActionButton:FloatingActionButton.extended(backgroundColor:forest,foregroundColor:Colors.white,
        onPressed:addBook,icon:const Icon(Icons.picture_as_pdf),label:const Text('إضافة كتاب PDF')),
      body:ListView(padding:const EdgeInsets.fromLTRB(16,8,16,110),children:[
        Container(padding:const EdgeInsets.all(22),decoration:BoxDecoration(color:forest,borderRadius:BorderRadius.circular(22)),
          child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            const Text('كل صفحة تقرّبك من الخِتام ✨',style:TextStyle(color:Colors.white,fontSize:20,fontWeight:FontWeight.bold)),
            const SizedBox(height:16),Row(children:[_stat('الكتب',books.length),_stat('المكتملة',completed),_stat('الصفحات',pagesRead)])])),
        const SizedBox(height:18),
        SegmentedButton<int>(segments:const [ButtonSegment(value:0,label:Text('الكل')),
          ButtonSegment(value:1,label:Text('أقرأ الآن')),
          ButtonSegment(value:2,label:Text('أنهيتها'))],selected:{tab},onSelectionChanged:(s)=>setState(()=>tab=s.first)),
        const SizedBox(height:16),
        if(shown.isEmpty)const Padding(padding:EdgeInsets.symmetric(vertical:55),child:Column(children:[
          Icon(Icons.auto_stories_outlined,size:64,color:gold),SizedBox(height:14),
          Text('مكتبتك تنتظر كتابك الأول',style:TextStyle(fontSize:18)),
          SizedBox(height:8),Text('أضف ملف PDF من جهازك وابدأ رحلتك')]))
        else ...shown.map((b)=>Card(margin:const EdgeInsets.only(bottom:12),child:Padding(
          padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Row(children:[const Icon(Icons.menu_book,color:forest,size:34),const SizedBox(width:12),
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text(b.title,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.bold,fontSize:17)),
                Text(b.finished?'مكتمل ✓':b.planDays>0?'${b.dailyTarget} صفحة يوميًا · ${b.planDays} يوم':'دون خطة بعد',style:const TextStyle(color:Colors.black54))])),
              PopupMenuButton<String>(onSelected:(v){if(v=='edit')editBook(b);if(v=='delete')removeBook(b);},itemBuilder:(_)=>[
                const PopupMenuItem(value:'edit',child:Text('تعديل الخطة')),
                const PopupMenuItem(value:'delete',child:Text('حذف الكتاب'))])]),
            const SizedBox(height:12),LinearProgressIndicator(value:b.pages>0?min(1,b.currentPage/b.pages):0,
              minHeight:7,borderRadius:BorderRadius.circular(8),color:gold,backgroundColor:Colors.black12),
            const SizedBox(height:6),Text('${b.currentPage} / ${b.pages==0?'…':b.pages} صفحة'),
            Align(alignment:Alignment.centerLeft,child:TextButton.icon(onPressed:()=>openBook(b),
              icon:const Icon(Icons.arrow_back),label:Text(b.currentPage==0?'ابدأ القراءة':'تابع القراءة')))
          ]))))
      ]));
  }
  Widget _stat(String label,int value)=>Expanded(child:Column(children:[
    Text('$value',style:const TextStyle(color:gold,fontSize:24,fontWeight:FontWeight.bold)),
    Text(label,style:const TextStyle(color:Colors.white70))]));
}

class BookSetup extends StatefulWidget {
  final Book book;final bool isNew;
  const BookSetup({super.key,required this.book,required this.isNew});
  @override State<BookSetup> createState()=>_BookSetupState();
}
class _BookSetupState extends State<BookSetup> {
  late final TextEditingController title,author,days;
  late TimeOfDay reminder;
  @override void initState(){super.initState();title=TextEditingController(text:widget.book.title);
    author=TextEditingController(text:widget.book.author);
    days=TextEditingController(text:widget.book.planDays>0?'${widget.book.planDays}':'14');
    reminder=TimeOfDay(hour:widget.book.reminderHour,minute:widget.book.reminderMinute);}
  @override void dispose(){title.dispose();author.dispose();days.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:Text(widget.isNew?'كتاب جديد':'تعديل خطة القراءة')),
    body:ListView(padding:const EdgeInsets.all(20),children:[
      TextField(controller:title,decoration:const InputDecoration(labelText:'اسم الكتاب',border:OutlineInputBorder())),
      const SizedBox(height:14),TextField(controller:author,decoration:const InputDecoration(labelText:'المؤلف (اختياري)',border:OutlineInputBorder())),
      const SizedBox(height:14),TextField(controller:days,keyboardType:TextInputType.number,
        decoration:const InputDecoration(labelText:'أريد إنهاء الكتاب خلال (أيام)',border:OutlineInputBorder())),
      const SizedBox(height:16),ListTile(title:const Text('وقت التذكير اليومي'),subtitle:Text(reminder.format(context)),
        trailing:const Icon(Icons.alarm),onTap:() async {final t=await showTimePicker(context:context,initialTime:reminder);if(t!=null)setState(()=>reminder=t);}),
      const SizedBox(height:22),FilledButton.icon(onPressed:(){
        final n=int.tryParse(days.text);
        if(title.text.trim().isEmpty || n==null || n<1 || n>3650){
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('أدخل اسمًا وعدد أيام صحيحًا (1–3650)')));return;}
        widget.book.title=title.text.trim();widget.book.author=author.text.trim();widget.book.planDays=n;
        widget.book.reminderHour=reminder.hour;widget.book.reminderMinute=reminder.minute;
        widget.book.started=DateTime.now();Navigator.pop(context,true);
      },icon:const Icon(Icons.check),label:const Text('حفظ خطة القراءة')),
      const SizedBox(height:12),const Text('سيُعرف عدد صفحات الكتاب تلقائيًا عند فتح ملف PDF أول مرة.',textAlign:TextAlign.center)
    ]));
}

class ReaderScreen extends StatefulWidget {
  final Book book;final Future<void> Function() onSaved;
  const ReaderScreen({super.key,required this.book,required this.onSaved});
  @override State<ReaderScreen> createState()=>_ReaderScreenState();
}
class _ReaderScreenState extends State<ReaderScreen> {
  int page=0;bool ready=false;
  @override void initState(){super.initState();page=max(0,widget.book.currentPage-1);}
  Future<void> update(int current) async {
    if(current>widget.book.currentPage){widget.book.currentPage=current;await widget.onSaved();}
    if(widget.book.finished)await Reminders.cancel(widget.book);
    if(mounted)setState(()=>page=current-1);
  }
  @override Widget build(BuildContext context){final b=widget.book;
    return Scaffold(appBar:AppBar(title:Text(b.title,maxLines:1,overflow:TextOverflow.ellipsis)),
      body:Column(children:[
        if(b.planDays>0)Container(width:double.infinity,color:const Color(0xFFE8E1CD),padding:const EdgeInsets.all(10),
          child:Text('هدفك اليوم: ${b.dailyTarget} صفحة · تقدّمك: ${b.currentPage} / ${b.pages}')),
        Expanded(child:PDFView(filePath:b.filePath,enableSwipe:true,swipeHorizontal:false,
          defaultPage:page,onRender:(count) async {
            if(count!=null && count>0){final changed=b.pages!=count;b.pages=count;await widget.onSaved();if(changed && !b.finished)await Reminders.schedule(b);if(mounted)setState(()=>ready=true);}
          },onPageChanged:(p,total){if(p!=null)update(p+1);},
          onError:(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('تعذر فتح PDF: $e')));})),
        if(ready)Padding(padding:const EdgeInsets.symmetric(horizontal:16,vertical:8),child:Row(children:[
          Expanded(child:LinearProgressIndicator(value:b.pages>0?min(1,b.currentPage/b.pages):0,
            color:gold,minHeight:7,borderRadius:BorderRadius.circular(7))),
          const SizedBox(width:12),Text('${page+1} / ${b.pages}')]))
      ]),floatingActionButton:FloatingActionButton.small(tooltip:'تسجيل الصفحة الحالية',
        onPressed:()=>update(page+1),child:const Icon(Icons.bookmark_added)));
  }
}
