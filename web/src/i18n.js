// Proview Label – on-screen language (English, Türkçe, Română, Български).
// Only what staff see on screen is translated. Printed labels are drawn separately (canvas / ESC/POS)
// and the on-screen label preview (.lab) is skipped, so prints always stay in English.
// How it works: a watcher translates every piece of text the app puts on screen, using the table below.
// Names the business types in (categories, products, storage locations, sites, people) are left as they are.
(function () {
  'use strict';
  const LANGS = [
    { code: 'en', name: 'English' },
    { code: 'tr', name: 'Türkçe' },
    { code: 'ro', name: 'Română' },
    { code: 'bg', name: 'Български' }
  ];
  const COL = { tr: 0, ro: 1, bg: 2 };
  const KEY = 'pvl_lang';

  // round flag icons
  const FLAGS = {
    en: '<svg viewBox="0 0 60 30" preserveAspectRatio="xMidYMid slice" aria-hidden="true"><clipPath id="pvl-uk-t"><path d="M30,15h30v15zv15h-30zh-30v-15zv-15h30z"/></clipPath><rect width="60" height="30" fill="#012169"/><path d="M0,0L60,30M60,0L0,30" stroke="#fff" stroke-width="6"/><path d="M0,0L60,30M60,0L0,30" clip-path="url(#pvl-uk-t)" stroke="#C8102E" stroke-width="4"/><path d="M30,0v30M0,15h60" stroke="#fff" stroke-width="10"/><path d="M30,0v30M0,15h60" stroke="#C8102E" stroke-width="6"/></svg>',
    tr: '<svg viewBox="0 0 30 20" preserveAspectRatio="xMidYMid slice" aria-hidden="true"><rect width="30" height="20" fill="#E30A17"/><circle cx="10.63" cy="10" r="5" fill="#fff"/><circle cx="11.88" cy="10" r="4" fill="#E30A17"/><polygon fill="#fff" points="12.08,10.00 13.81,9.44 13.81,7.62 14.88,9.09 16.60,8.53 15.54,10.00 16.60,11.47 14.88,10.91 13.81,12.38 13.81,10.56"/></svg>',
    ro: '<svg viewBox="0 0 3 2" preserveAspectRatio="xMidYMid slice" aria-hidden="true"><rect width="1" height="2" fill="#002B7F"/><rect x="1" width="1" height="2" fill="#FCD116"/><rect x="2" width="1" height="2" fill="#CE1126"/></svg>',
    bg: '<svg viewBox="0 0 5 3" preserveAspectRatio="xMidYMid slice" aria-hidden="true"><rect width="5" height="1" fill="#fff"/><rect y="1" width="5" height="1" fill="#00966E"/><rect y="2" width="5" height="1" fill="#D62612"/></svg>'
  };

  // English → [Türkçe, Română, Български]
  const D = {
    // header, menu, chrome
    'Categories': ['Kategoriler', 'Categorii', 'Категории'],
    'Products': ['Ürünler', 'Produse', 'Продукти'],
    'Search': ['Ara', 'Căutare', 'Търсене'],
    'Storage Location': ['Saklama Yeri', 'Loc de depozitare', 'Място на съхранение'],
    'Bulk': ['Toplu', 'În masă', 'Масов'],
    'Bulk Print': ['Toplu Yazdır', 'Tipărire în masă', 'Масов печат'],
    'Scan to Print': ['Tarayıp Yazdır', 'Scanează și tipărește', 'Сканирай и печатай'],
    'Logs': ['Kayıtlar', 'Jurnale', 'Дневници'],
    'Expiry Report': ['Son Kullanma Raporu', 'Raport expirări', 'Отчет за срокове'],
    'Print Log': ['Yazdırma Kaydı', 'Jurnal tipăriri', 'Дневник на печата'],
    'Wastage Log': ['Fire Kaydı', 'Jurnal deșeuri', 'Дневник на брака'],
    'Log Wastage': ['Fire Kaydet', 'Înregistrează deșeuri', 'Запиши брак'],
    'Log wastage': ['Fire kaydet', 'Înregistrează deșeuri', 'Запиши брак'],
    'Label Order': ['Etiket Siparişi', 'Comandă etichete', 'Поръчка на етикети'],
    'Manage Profiles': ['Profilleri Yönet', 'Gestionează profilurile', 'Управление на профили'],
    'About Device': ['Cihaz Hakkında', 'Despre dispozitiv', 'За устройството'],
    'Support': ['Destek', 'Asistență', 'Поддръжка'],
    'Settings': ['Ayarlar', 'Setări', 'Настройки'],
    'Menu': ['Menü', 'Meniu', 'Меню'],
    'Back': ['Geri', 'Înapoi', 'Назад'],
    'Sync': ['Senkronize et', 'Sincronizare', 'Синхронизиране'],
    'Switch profile': ['Profil değiştir', 'Schimbă profilul', 'Смяна на профил'],
    'Switch Profiles': ['Profil Değiştir', 'Schimbă profilul', 'Смяна на профил'],
    'Switch between Easy and Detailed mode': ['Kolay ve Detaylı mod arasında geç', 'Comută între modul simplu și detaliat', 'Превключване между лесен и подробен режим'],
    'Switch mode': ['Modu değiştir', 'Schimbă modul', 'Смяна на режима'],
    'Easy': ['Kolay', 'Simplu', 'Лесен'],
    'Detailed': ['Detaylı', 'Detaliat', 'Подробен'],
    'Easy mode: tap a product, then Print': ['Kolay mod: bir ürüne dokunun, sonra Yazdır', 'Mod simplu: atinge un produs, apoi Tipărește', 'Лесен режим: докоснете продукт, после Печат'],
    'Detailed mode: all options': ['Detaylı mod: tüm seçenekler', 'Mod detaliat: toate opțiunile', 'Подробен режим: всички опции'],
    'Language': ['Dil', 'Limbă', 'Език'],
    'Screen language. Labels always print in English.': ['Ekran dili. Etiketler her zaman İngilizce yazdırılır.', 'Limba ecranului. Etichetele se tipăresc mereu în engleză.', 'Език на екрана. Етикетите винаги се печатат на английски.'],
    'Syncing…': ['Senkronize ediliyor…', 'Se sincronizează…', 'Синхронизиране…'],
    'Connected': ['Bağlı', 'Conectat', 'Свързано'],
    'Not connected': ['Bağlı değil', 'Neconectat', 'Не е свързано'],
    'Demo data': ['Demo verisi', 'Date demo', 'Демо данни'],
    'Offline – printing still works': ['Çevrimdışı – yazdırma çalışıyor', 'Offline – tipărirea funcționează', 'Офлайн – печатът работи'],
    'syncing paused': ['senkronizasyon durduruldu', 'sincronizare oprită', 'синхронизацията е спряна'],
    'Misc': ['Diğer', 'Diverse', 'Разни'],
    'Storage': ['Saklama', 'Depozitare', 'Съхранение'],
    'Print queue': ['Yazdırma kuyruğu', 'Coadă de tipărire', 'Опашка за печат'],
    'Print Screen': ['Yazdırma Ekranı', 'Ecran de tipărire', 'Екран за печат'],
    'Scan to print mode': ['Tarayıp yazdırma modu', 'Mod scanare și tipărire', 'Режим сканиране и печат'],
    'Wastage': ['Fire', 'Deșeuri', 'Брак'],
    'Check for updates': ['Güncellemeleri kontrol et', 'Caută actualizări', 'Проверка за обновления'],
    'signed in': ['oturum açık', 'conectat', 'вписан'],
    'just now': ['az önce', 'chiar acum', 'току-що'],

    // home / products
    'Prep': ['Hazırlık', 'Preparare', 'Подготовка'],
    'Sale': ['Satış', 'Vânzare', 'Продажба'],
    'No categories yet': ['Henüz kategori yok', 'Încă nu există categorii', 'Все още няма категории'],
    'A manager can add them in Detailed mode or on label.proviewcrm.co.uk.': ['Bir yönetici bunları Detaylı modda veya label.proviewcrm.co.uk adresinde ekleyebilir.', 'Un manager le poate adăuga în modul detaliat sau pe label.proviewcrm.co.uk.', 'Мениджър може да ги добави в подробен режим или на label.proviewcrm.co.uk.'],
    'One less': ['Bir eksik', 'Unul mai puțin', 'Един по-малко'],
    'One more': ['Bir fazla', 'Încă unul', 'Още един'],
    'Print': ['Yazdır', 'Tipărește', 'Печат'],
    'Add new': ['Yeni ekle', 'Adaugă', 'Добави нов'],
    'Sort A–Z': ['A–Z sırala', 'Sortare A–Z', 'Сортиране А–Я'],
    'Freq. Printed': ['Sık yazdırılan', 'Tipărite des', 'Често печатани'],
    'No products found': ['Ürün bulunamadı', 'Niciun produs găsit', 'Няма намерени продукти'],
    'Create a new product and it will be stored here.': ['Yeni bir ürün oluşturun, burada saklanacak.', 'Creează un produs nou și va apărea aici.', 'Създайте нов продукт и той ще се появи тук.'],
    'Search products or scan barcode': ['Ürün ara veya barkod tara', 'Caută produse sau scanează codul de bare', 'Търсете продукт или сканирайте баркод'],
    'No matches': ['Eşleşme yok', 'Niciun rezultat', 'Няма съвпадения'],
    'Try another name.': ['Başka bir ad deneyin.', 'Încearcă alt nume.', 'Опитайте друго име.'],
    'Storage location sets the default use-by date for prep labels. Products with their own expiry rule always use that rule.': ['Saklama yeri, hazırlık etiketlerindeki varsayılan son kullanma tarihini belirler. Kendi son kullanma kuralı olan ürünler her zaman o kuralı kullanır.', 'Locul de depozitare stabilește data de expirare implicită pentru etichetele de preparare. Produsele cu regulă proprie de expirare folosesc mereu acea regulă.', 'Мястото на съхранение задава срока по подразбиране за етикетите за подготовка. Продуктите със собствено правило за срок винаги използват него.'],

    // logs
    'Every label printed and who printed it': ['Yazdırılan her etiket ve yazdıran kişi', 'Fiecare etichetă tipărită și cine a tipărit-o', 'Всеки отпечатан етикет и кой го е отпечатал'],
    'Discarded items with reason and quantity': ['Atılan ürünler, neden ve miktarıyla', 'Produse aruncate, cu motiv și cantitate', 'Изхвърлени продукти с причина и количество'],
    'Action': ['İşlem gerekli', 'Acțiune', 'Действие'],
    'Expired': ['Süresi geçmiş', 'Expirat', 'Изтекъл'],
    'Today': ['Bugün', 'Azi', 'Днес'],
    'OK': ['Tamam', 'OK', 'ОК'],
    'Used': ['Kullanıldı', 'Folosit', 'Използван'],
    'Waste': ['Fire', 'Aruncă', 'Брак'],
    'Nothing else tracked.': ['Takip edilen başka bir şey yok.', 'Nimic altceva urmărit.', 'Няма други следени.'],
    '7 days': ['7 gün', '7 zile', '7 дни'],
    'All': ['Tümü', 'Toate', 'Всички'],
    'Reprint': ['Yeniden yazdır', 'Retipărește', 'Препечатай'],
    'No labels printed in this period.': ['Bu dönemde etiket yazdırılmadı.', 'Nicio etichetă tipărită în această perioadă.', 'Няма отпечатани етикети за този период.'],
    'items wasted': ['atılan ürün', 'produse aruncate', 'бракувани бройки'],
    'estimated cost': ['tahmini maliyet', 'cost estimat', 'приблизителна стойност'],
    'No wastage logged.': ['Fire kaydı yok.', 'Niciun deșeu înregistrat.', 'Няма записан брак.'],
    'Record anything thrown away. Managers see wastage reports in the Proview back-office.': ['Atılan her şeyi kaydedin. Yöneticiler fire raporlarını Proview yönetim panelinde görür.', 'Înregistrează tot ce se aruncă. Managerii văd rapoartele de deșeuri în back-office-ul Proview.', 'Записвайте всичко изхвърлено. Мениджърите виждат отчетите за брак в бек офиса на Proview.'],
    'View wastage log': ['Fire kaydını gör', 'Vezi jurnalul de deșeuri', 'Виж дневника на брака'],

    // bulk / scan
    'No products found in this category.': ['Bu kategoride ürün yok.', 'Niciun produs în această categorie.', 'Няма продукти в тази категория.'],
    'Reset': ['Sıfırla', 'Resetează', 'Нулирай'],
    'Preview': ['Önizleme', 'Previzualizare', 'Преглед'],
    'All labels will be re-printed with a date of:': ['Tüm etiketler şu tarihle yeniden yazdırılacak:', 'Toate etichetele vor fi retipărite cu data:', 'Всички етикети ще се препечатат с дата:'],
    'Point the camera at a label barcode': ['Kamerayı etiket barkoduna tutun', 'Îndreaptă camera spre codul de bare al etichetei', 'Насочете камерата към баркода на етикета'],
    'Start camera': ['Kamerayı başlat', 'Pornește camera', 'Включи камерата'],
    'Or type / scan code (e.g. PV…)': ['Veya kodu yazın / tarayın (ör. PV…)', 'Sau tastează / scanează codul (ex. PV…)', 'Или въведете / сканирайте код (напр. PV…)'],
    'Scan to print mode ignores any custom expiry date and storage location. Handheld scanners that type into the box work too.': ['Tarayıp yazdırma modu özel son kullanma tarihini ve saklama yerini dikkate almaz. Kutuya yazan el tarayıcıları da çalışır.', 'Modul scanare și tipărire ignoră data de expirare personalizată și locul de depozitare. Funcționează și scanerele care scriu în casetă.', 'Режимът сканиране и печат пренебрегва ръчния срок и мястото на съхранение. Работят и скенери, които пишат в полето.'],
    'Recent labels (tap to simulate a scan)': ['Son etiketler (tarama denemek için dokunun)', 'Etichete recente (atinge pentru a simula o scanare)', 'Последни етикети (докоснете, за да симулирате сканиране)'],
    'Camera scanning needs the Android app. Type the code instead.': ['Kamerayla tarama Android uygulamasında çalışır. Kodu yazın.', 'Scanarea cu camera necesită aplicația Android. Tastează codul.', 'Сканирането с камера изисква Android приложението. Въведете кода.'],

    // label order
    'On-demand': ['Tek seferlik', 'La cerere', 'При нужда'],
    'Recurring': ['Düzenli', 'Recurentă', 'Периодична'],
    'on-demand': ['tek seferlik', 'la cerere', 'при нужда'],
    'recurring': ['düzenli', 'recurentă', 'периодична'],
    'Labels printed to date': ['Bugüne kadar yazdırılan etiket', 'Etichete tipărite până acum', 'Отпечатани етикети досега'],
    'Stock last ordered': ['Son stok siparişi', 'Ultima comandă de stoc', 'Последна поръчка на ролки'],
    'Average weekly labels': ['Haftalık ortalama etiket', 'Media săptămânală de etichete', 'Средно етикети на седмица'],
    'Labels left on roll': ['Ruloda kalan etiket', 'Etichete rămase pe rolă', 'Оставащи етикети на ролката'],
    'Label type': ['Etiket türü', 'Tip etichetă', 'Вид етикет'],
    'Frequency': ['Sıklık', 'Frecvență', 'Честота'],
    'Every 2 weeks': ['2 haftada bir', 'La fiecare 2 săptămâni', 'На всеки 2 седмици'],
    'Every 4 weeks': ['4 haftada bir', 'La fiecare 4 săptămâni', 'На всеки 4 седмици'],
    'Every 8 weeks': ['8 haftada bir', 'La fiecare 8 săptămâni', 'На всеки 8 седмици'],
    'Quantity (rolls)': ['Miktar (rulo)', 'Cantitate (role)', 'Количество (ролки)'],
    'Delivery': ['Teslimat', 'Livrare', 'Доставка'],
    'Send via Royal Mail 24 Hour Service': ['Royal Mail 24 Saat Servisi ile gönder', 'Trimite prin Royal Mail 24 de ore', 'Изпрати с Royal Mail 24 часа'],
    'Set up recurring order': ['Düzenli sipariş oluştur', 'Configurează comanda recurentă', 'Настрой периодична поръчка'],
    'Order label rolls': ['Etiket rulosu sipariş et', 'Comandă role de etichete', 'Поръчай ролки етикети'],
    'Previous orders': ['Önceki siparişler', 'Comenzi anterioare', 'Предишни поръчки'],
    'No orders yet.': ['Henüz sipariş yok.', 'Încă nu există comenzi.', 'Все още няма поръчки.'],
    'pending': ['beklemede', 'în așteptare', 'изчаква'],
    'dispatched': ['gönderildi', 'expediată', 'изпратена'],
    'delivered': ['teslim edildi', 'livrată', 'доставена'],
    'cancelled': ['iptal edildi', 'anulată', 'отказана'],
    'Single Height (40mm)': ['Tek Yükseklik (40mm)', 'Înălțime simplă (40mm)', 'Единична височина (40mm)'],
    'Double Height (80mm)': ['Çift Yükseklik (80mm)', 'Înălțime dublă (80mm)', 'Двойна височина (80mm)'],
    'Single Height – Easy Peel (40mm)': ['Tek Yükseklik – Kolay Soyulur (40mm)', 'Înălțime simplă – dezlipire ușoară (40mm)', 'Единична височина – лесно отлепяне (40mm)'],
    '40mm label for prep and small ingredient labels. 180 per roll.': ['Hazırlık ve kısa içerik etiketleri için 40mm etiket. Rulo başına 180.', 'Etichetă de 40mm pentru preparare și liste scurte de ingrediente. 180 pe rolă.', 'Етикет 40mm за подготовка и кратки съставки. 180 на ролка.'],
    '80mm label for long or complex ingredient labels. 90 per roll.': ['Uzun veya karmaşık içerik listeleri için 80mm etiket. Rulo başına 90.', 'Etichetă de 80mm pentru liste lungi sau complexe de ingrediente. 90 pe rolă.', 'Етикет 80mm за дълги или сложни съставки. 90 на ролка.'],
    'Low-adhesive 40mm label, less residue and tearing on removal.': ['Az yapışkanlı 40mm etiket; sökerken daha az iz ve yırtılma.', 'Etichetă de 40mm cu adeziv slab, lasă mai puține urme și nu se rupe la dezlipire.', 'Етикет 40mm със слабо лепило – по-малко остатъци и скъсване при махане.'],
    'Confirm order': ['Siparişi onayla', 'Confirmă comanda', 'Потвърди поръчката'],
    'Place order': ['Sipariş ver', 'Plasează comanda', 'Направи поръчка'],
    'Order sent to Proview': ['Sipariş Proview’e gönderildi', 'Comanda a fost trimisă la Proview', 'Поръчката е изпратена до Proview'],
    'Cancel': ['İptal', 'Anulează', 'Отказ'],
    'weeks': ['hafta', 'săptămâni', 'седмици'],

    // profiles / roles
    'Add profile': ['Profil ekle', 'Adaugă profil', 'Добави профил'],
    'Staff can print, scan and log wastage. Managers can also edit products, categories, storage rules and profiles. Admins manage everything, including other sites, from the back-office.': ['Personel yazdırabilir, tarayabilir ve fire kaydedebilir. Müdürler ayrıca ürünleri, kategorileri, saklama kurallarını ve profilleri düzenleyebilir. Yöneticiler diğer şubeler dahil her şeyi yönetim panelinden yönetir.', 'Personalul poate tipări, scana și înregistra deșeuri. Managerii pot edita și produse, categorii, reguli de depozitare și profiluri. Administratorii gestionează totul, inclusiv alte locații, din back-office.', 'Персоналът може да печата, сканира и записва брак. Мениджърите могат и да редактират продукти, категории, правила за съхранение и профили. Администраторите управляват всичко, включително други обекти, от бек офиса.'],
    'Master': ['Ana yönetici', 'Master', 'Главен администратор'],
    'Admin': ['Yönetici', 'Administrator', 'Администратор'],
    'Manager': ['Müdür', 'Manager', 'Мениджър'],
    'Staff': ['Personel', 'Personal', 'Персонал'],
    'Not signed in': ['Oturum açılmadı', 'Neautentificat', 'Не сте вписани'],

    // about
    'App version': ['Uygulama sürümü', 'Versiune aplicație', 'Версия на приложението'],
    'Device ID': ['Cihaz kimliği', 'ID dispozitiv', 'ID на устройството'],
    'Platform': ['Platform', 'Platformă', 'Платформа'],
    'Android app': ['Android uygulaması', 'Aplicație Android', 'Android приложение'],
    'Web preview': ['Web önizleme', 'Previzualizare web', 'Уеб преглед'],
    'Battery': ['Pil', 'Baterie', 'Батерия'],
    'Network': ['Ağ', 'Rețea', 'Мрежа'],
    'Online': ['Çevrimiçi', 'Online', 'Онлайн'],
    'Offline': ['Çevrimdışı', 'Offline', 'Офлайн'],
    'Printer': ['Yazıcı', 'Imprimantă', 'Принтер'],
    'Screen preview only': ['Yalnızca ekran önizlemesi', 'Doar previzualizare pe ecran', 'Само преглед на екрана'],
    'Built-in printer': ['Dahili yazıcı', 'Imprimantă integrată', 'Вграден принтер'],
    'Products / categories': ['Ürünler / kategoriler', 'Produse / categorii', 'Продукти / категории'],
    'Back-office sync': ['Yönetim paneli senkronizasyonu', 'Sincronizare back-office', 'Синхронизация с бек офиса'],
    'Site address': ['Şube adresi', 'Adresa locației', 'Адрес на обекта'],
    'Proview Label device': ['Proview Label cihazı', 'Dispozitiv Proview Label', 'Устройство Proview Label'],

    // support
    'Proview support': ['Proview destek', 'Asistență Proview', 'Поддръжка Proview'],
    'Phone': ['Telefon', 'Telefon', 'Телефон'],
    'Email': ['E-posta', 'E-mail', 'Имейл'],
    'Report a problem': ['Sorun bildir', 'Raportează o problemă', 'Съобщи за проблем'],
    'Printer not printing': ['Yazıcı yazdırmıyor', 'Imprimanta nu tipărește', 'Принтерът не печата'],
    'Label quality / jams': ['Etiket kalitesi / sıkışma', 'Calitatea etichetelor / blocaje', 'Качество на етикетите / засядане'],
    'Product or allergen data': ['Ürün veya alerjen bilgisi', 'Date despre produse sau alergeni', 'Данни за продукт или алергени'],
    'Device or battery': ['Cihaz veya pil', 'Dispozitiv sau baterie', 'Устройство или батерия'],
    'Something else': ['Başka bir şey', 'Altceva', 'Друго'],
    'What happened?': ['Ne oldu?', 'Ce s-a întâmplat?', 'Какво се случи?'],
    'Send to Proview': ['Proview’e gönder', 'Trimite la Proview', 'Изпрати до Proview'],
    'Quick fixes': ['Hızlı çözümler', 'Soluții rapide', 'Бързи решения'],
    'Labels printing blank?': ['Etiketler boş mu çıkıyor?', 'Etichetele ies goale?', 'Етикетите излизат празни?'],
    'Thermal labels print on one side only – reload the roll with the shiny side facing the print head.': ['Termal etiketler yalnızca tek yüze basılır – ruloyu parlak yüzü yazıcı kafasına bakacak şekilde yeniden takın.', 'Etichetele termice se tipăresc doar pe o față – pune rola din nou cu partea lucioasă spre capul de imprimare.', 'Термоетикетите се печатат само от едната страна – поставете ролката отново с лъскавата страна към печатащата глава.'],
    'Wrong use-by date?': ['Son kullanma tarihi yanlış mı?', 'Data de expirare greșită?', 'Грешен срок на годност?'],
    'Check the storage location at the bottom of the print screen, or the product\'s custom expiry rule.': ['Yazdırma ekranının altındaki saklama yerini veya ürünün özel son kullanma kuralını kontrol edin.', 'Verifică locul de depozitare din partea de jos a ecranului de tipărire sau regula de expirare a produsului.', 'Проверете мястото на съхранение долу на екрана за печат или собственото правило за срок на продукта.'],
    'Products missing?': ['Ürünler eksik mi?', 'Lipsesc produse?', 'Липсват продукти?'],
    'Tap the sync button at the top to pull the latest from the back-office.': ['Yönetim panelindeki son verileri almak için üstteki senkronizasyon düğmesine dokunun.', 'Atinge butonul de sincronizare de sus pentru a aduce ultimele date din back-office.', 'Докоснете бутона за синхронизиране горе, за да изтеглите последните данни от бек офиса.'],
    'Describe the problem first': ['Önce sorunu açıklayın', 'Descrie mai întâi problema', 'Първо опишете проблема'],
    'Sent. Ticket logged for Proview support.': ['Gönderildi. Proview destek kaydı oluşturuldu.', 'Trimis. Solicitarea a fost înregistrată la asistența Proview.', 'Изпратено. Заявката е регистрирана в поддръжката на Proview.'],

    // settings
    'Site': ['Şube', 'Locație', 'Обект'],
    'Built-in': ['Dahili', 'Integrată', 'Вграден'],
    'Bluetooth': ['Bluetooth', 'Bluetooth', 'Bluetooth'],
    'Paired printer': ['Eşleşmiş yazıcı', 'Imprimantă asociată', 'Сдвоен принтер'],
    'Find printers': ['Yazıcı bul', 'Caută imprimante', 'Намери принтери'],
    'Tap “Find printers”': ['“Yazıcı bul”a dokunun', 'Atinge „Caută imprimante”', 'Докоснете „Намери принтери“'],
    'Printer IP': ['Yazıcı IP', 'IP imprimantă', 'IP на принтера'],
    'Port': ['Port', 'Port', 'Порт'],
    'Checking for a built-in printer…': ['Dahili yazıcı aranıyor…', 'Se caută imprimanta integrată…', 'Търсене на вграден принтер…'],
    'Built-in printer ready': ['Dahili yazıcı hazır', 'Imprimanta integrată este gata', 'Вграденият принтер е готов'],
    'No built-in printer found': ['Dahili yazıcı bulunamadı', 'Nu s-a găsit imprimantă integrată', 'Няма вграден принтер'],
    'Built-in printing works on Senraise handhelds such as the H10P and H10S. On other devices choose Bluetooth or Network.': ['Dahili yazdırma H10P ve H10S gibi Senraise el cihazlarında çalışır. Diğer cihazlarda Bluetooth veya Ağ seçin.', 'Tipărirea integrată funcționează pe terminalele Senraise, de ex. H10P și H10S. Pe alte dispozitive alege Bluetooth sau Rețea.', 'Вграденият печат работи на терминали Senraise като H10P и H10S. На други устройства изберете Bluetooth или Мрежа.'],
    'Simple text labels (faster, no £ sign)': ['Basit metin etiketleri (daha hızlı, £ işareti yok)', 'Etichete doar text (mai rapid, fără semnul £)', 'Само текстови етикети (по-бързо, без знак £)'],
    'Labels are printed as a picture, exactly as they look on screen. Tear off at the dashed line.': ['Etiketler ekranda göründüğü gibi resim olarak yazdırılır. Kesikli çizgiden koparın.', 'Etichetele se tipăresc ca imagine, exact cum apar pe ecran. Rupe pe linia punctată.', 'Етикетите се печатат като картина, точно както изглеждат на екрана. Откъснете по пунктирната линия.'],
    'Uses ESC/POS commands. Works with most 58mm/80mm thermal printers.': ['ESC/POS komutlarını kullanır. Çoğu 58mm/80mm termal yazıcıyla çalışır.', 'Folosește comenzi ESC/POS. Funcționează cu majoritatea imprimantelor termice de 58mm/80mm.', 'Използва ESC/POS команди. Работи с повечето термопринтери 58mm/80mm.'],
    'Print test label': ['Test etiketi yazdır', 'Tipărește o etichetă de test', 'Отпечатай тестов етикет'],
    'Proview Label cloud': ['Proview Label bulut', 'Cloud Proview Label', 'Облак Proview Label'],
    'Sync now': ['Şimdi senkronize et', 'Sincronizează acum', 'Синхронизирай сега'],
    'Disconnect': ['Bağlantıyı kes', 'Deconectează', 'Прекъсни връзката'],
    'Connect to Proview Label': ['Proview Label’a bağlan', 'Conectează la Proview Label', 'Свържи с Proview Label'],
    'This preview runs on demo data. In the Android app, connect here to sync with the live back-office.': ['Bu önizleme demo verisiyle çalışır. Android uygulamasında canlı yönetim paneliyle senkronize olmak için buradan bağlanın.', 'Această previzualizare folosește date demo. În aplicația Android, conectează-te aici pentru sincronizare cu back-office-ul.', 'Този преглед работи с демо данни. В Android приложението се свържете оттук за синхронизация с бек офиса.'],
    'Sync this handheld with the back-office at label.proviewcrm.co.uk: products, staff and settings come down; labels, expiry and wastage go up.': ['Bu el cihazını label.proviewcrm.co.uk yönetim paneliyle senkronize edin: ürünler, personel ve ayarlar iner; etiketler, son kullanma ve fire kayıtları gönderilir.', 'Sincronizează acest terminal cu back-office-ul de pe label.proviewcrm.co.uk: produsele, personalul și setările vin pe terminal; etichetele, expirările și deșeurile sunt trimise.', 'Синхронизирайте този терминал с бек офиса на label.proviewcrm.co.uk: продуктите, персоналът и настройките се изтеглят; етикетите, сроковете и бракът се изпращат.'],
    'Data': ['Veri', 'Date', 'Данни'],
    'Export data': ['Verileri dışa aktar', 'Exportă datele', 'Експорт на данни'],
    'Import data': ['Verileri içe aktar', 'Importă datele', 'Импорт на данни'],
    'Reset demo data': ['Demo verilerini sıfırla', 'Resetează datele demo', 'Нулирай демо данните'],
    'Reset demo data?': ['Demo verileri sıfırlansın mı?', 'Resetezi datele demo?', 'Да се нулират ли демо данните?'],
    'This deletes everything on this device and reloads the sample products and logs.': ['Bu cihazdaki her şey silinir ve örnek ürünler ile kayıtlar yeniden yüklenir.', 'Se șterge tot de pe acest dispozitiv și se reîncarcă produsele și jurnalele demo.', 'Изтрива всичко на устройството и зарежда отново примерните продукти и дневници.'],
    'Data imported': ['Veriler içe aktarıldı', 'Date importate', 'Данните са импортирани'],
    'Not a valid Proview export': ['Geçerli bir Proview dışa aktarımı değil', 'Nu este un export Proview valid', 'Невалиден експорт на Proview'],
    'Demo data restored': ['Demo verileri geri yüklendi', 'Datele demo au fost restaurate', 'Демо данните са възстановени'],
    'Bluetooth printing is available in the Android app': ['Bluetooth yazdırma Android uygulamasında kullanılabilir', 'Tipărirea Bluetooth este disponibilă în aplicația Android', 'Bluetooth печатът е наличен в Android приложението'],
    'No paired printers. Pair one in Android Bluetooth settings.': ['Eşleşmiş yazıcı yok. Android Bluetooth ayarlarından eşleştirin.', 'Nicio imprimantă asociată. Asociază una din setările Bluetooth Android.', 'Няма сдвоени принтери. Сдвоете от Bluetooth настройките на Android.'],
    'Last sync': ['Son senkronizasyon', 'Ultima sincronizare', 'Последна синхронизация'],

    // category / storage forms
    'New Category': ['Yeni Kategori', 'Categorie nouă', 'Нова категория'],
    'Category Name': ['Kategori Adı', 'Nume categorie', 'Име на категория'],
    'Colour Code': ['Renk Kodu', 'Culoare', 'Цвят'],
    'Default': ['Varsayılan', 'Implicit', 'По подразбиране'],
    'Red': ['Kırmızı', 'Roșu', 'Червен'],
    'Blue': ['Mavi', 'Albastru', 'Син'],
    'Purple': ['Mor', 'Mov', 'Лилав'],
    'Green': ['Yeşil', 'Verde', 'Зелен'],
    'Yellow': ['Sarı', 'Galben', 'Жълт'],
    'Navy': ['Lacivert', 'Bleumarin', 'Тъмносин'],
    'Teal': ['Camgöbeği', 'Turcoaz', 'Синьозелен'],
    'Created under': ['Şurada oluşturulacak:', 'Se creează la', 'Създава се в'],
    'Create category': ['Kategori oluştur', 'Creează categoria', 'Създай категория'],
    'Category created': ['Kategori oluşturuldu', 'Categorie creată', 'Категорията е създадена'],
    'New Storage Location': ['Yeni Saklama Yeri', 'Loc de depozitare nou', 'Ново място за съхранение'],
    'Name': ['Ad', 'Nume', 'Име'],
    'e.g. Blast chiller': ['ör. Şok soğutucu', 'ex. Răcitor rapid', 'напр. Шоков охладител'],
    'Shelf life': ['Raf ömrü', 'Termen de valabilitate', 'Срок на годност'],
    'Unit': ['Birim', 'Unitate', 'Единица'],
    'hours': ['saat', 'ore', 'часа'], 'hour': ['saat', 'oră', 'час'],
    'days': ['gün', 'zile', 'дни'], 'day': ['gün', 'zi', 'ден'],
    'months': ['ay', 'luni', 'месеца'], 'month': ['ay', 'lună', 'месец'],
    'Create': ['Oluştur', 'Creează', 'Създай'],
    'Enter a name': ['Bir ad girin', 'Introdu un nume', 'Въведете име'],
    'Only managers can do this. Ask a manager to change it in the back-office.': ['Bunu yalnızca müdürler yapabilir. Yönetim panelinden değiştirmesi için bir müdüre başvurun.', 'Doar managerii pot face asta. Roagă un manager să schimbe din back-office.', 'Само мениджъри могат да направят това. Помолете мениджър да го промени от бек офиса.'],
    'Pair this handheld': ['Bu cihazı eşleştir', 'Asociază acest terminal', 'Сдвояване на терминала'],
    'In the back-office at label.proviewcrm.co.uk, go to Locations & devices → Pair handheld and enter this code.': ['label.proviewcrm.co.uk yönetim panelinde Locations & devices → Pair handheld bölümüne gidin ve bu kodu girin.', 'În back-office pe label.proviewcrm.co.uk, mergi la Locations & devices → Pair handheld și introdu acest cod.', 'В бек офиса на label.proviewcrm.co.uk отидете на Locations & devices → Pair handheld и въведете този код.'],
    'Or scan the QR code with your phone.': ['Veya QR kodunu telefonunuzla okutun.', 'Sau scanează codul QR cu telefonul.', 'Или сканирайте QR кода с телефона си.'],
    'Waiting to be paired…': ['Eşleştirme bekleniyor…', 'Se așteaptă asocierea…', 'Изчакване на сдвояване…'],
    'Getting a code…': ['Kod alınıyor…', 'Se obține un cod…', 'Получаване на код…'],
    'Paired': ['Eşleştirildi', 'Asociat', 'Сдвоен'],
    'Not paired yet': ['Henüz eşleştirilmedi', 'Încă neasociat', 'Все още не е сдвоен'],
    'Unpair': ['Eşleştirmeyi kaldır', 'Dezasociază', 'Премахни сдвояването'],
    'Unpair this handheld': ['Bu cihazın eşleştirmesini kaldır', 'Dezasociază acest terminal', 'Премахни сдвояването на терминала'],
    'Unpair this handheld?': ['Bu cihazın eşleştirmesi kaldırılsın mı?', 'Dezasociezi acest terminal?', 'Да се премахне ли сдвояването на терминала?'],
    'It stops syncing and shows a new pairing code. Labels already sent stay in the back-office.': ['Senkronizasyon durur ve yeni bir eşleştirme kodu gösterilir. Gönderilmiş etiketler yönetim panelinde kalır.', 'Sincronizarea se oprește și apare un cod nou de asociere. Etichetele deja trimise rămân în back-office.', 'Синхронизацията спира и се показва нов код за сдвояване. Изпратените етикети остават в бек офиса.'],
    'Mode': ['Mod', 'Mod', 'Режим'],
    'Change the location in the back-office: Locations & devices.': ['Konumu yönetim panelinden değiştirin: Locations & devices.', 'Schimbă locația din back-office: Locations & devices.', 'Сменете обекта от бек офиса: Locations & devices.'],
    'This preview runs on demo data. The Android app is paired from the back-office with a code.': ['Bu önizleme demo verisiyle çalışır. Android uygulaması yönetim panelinden bir kodla eşleştirilir.', 'Această previzualizare folosește date demo. Aplicația Android se asociază din back-office cu un cod.', 'Този преглед работи с демо данни. Android приложението се сдвоява от бек офиса с код.'],
    'Manager access needed': ['Müdür yetkisi gerekli', 'Este nevoie de acces de manager', 'Нужен е достъп на мениджър'],
    'Only managers and admins can do this. Switch to a manager profile to continue.': ['Bunu yalnızca müdürler ve yöneticiler yapabilir. Devam etmek için bir müdür profiline geçin.', 'Doar managerii și administratorii pot face asta. Treci pe un profil de manager pentru a continua.', 'Само мениджъри и администратори могат да направят това. Превключете на профил на мениджър.'],

    // product form
    'Picture': ['Resim', 'Imagine', 'Снимка'],
    'shown on the product button': ['ürün düğmesinde gösterilir', 'apare pe butonul produsului', 'показва се на бутона на продукта'],
    'Change picture': ['Resmi değiştir', 'Schimbă imaginea', 'Смени снимката'],
    'Add picture': ['Resim ekle', 'Adaugă imagine', 'Добави снимка'],
    'Remove': ['Kaldır', 'Elimină', 'Премахни'],
    'Product Name': ['Ürün Adı', 'Nume produs', 'Име на продукта'],
    'Description': ['Açıklama', 'Descriere', 'Описание'],
    'optional · shown on the button': ['isteğe bağlı · düğmede gösterilir', 'opțional · apare pe buton', 'по избор · показва се на бутона'],
    'e.g. 6oz, served in a brioche bun': ['ör. 170 g, brioş ekmeğinde', 'ex. 170 g, servit în chiflă brioșă', 'напр. 170 г, в бриош хлебче'],
    'Ingredients': ['İçindekiler', 'Ingrediente', 'Съставки'],
    'Auto-bold allergens': ['Alerjenleri otomatik kalın yap', 'Îngroașă automat alergenii', 'Удебели алергените'],
    'Price (£)': ['Fiyat (£)', 'Preț (£)', 'Цена (£)'],
    'Date type': ['Tarih türü', 'Tip dată', 'Вид дата'],
    'Use by': ['Son kullanma', 'A se consuma până la', 'Използвай до'],
    'Best before': ['Tavsiye edilen tüketim', 'A se consuma de preferință înainte de', 'Най-добър до'],
    'Best Before': ['Tavsiye Edilen Tüketim', 'A se consuma de preferință înainte de', 'Най-добър до'],
    'Custom Expiry Rule': ['Özel Son Kullanma Kuralı', 'Regulă de expirare proprie', 'Собствено правило за срок'],
    'Use storage location': ['Saklama yerini kullan', 'Folosește locul de depozitare', 'Използвай мястото на съхранение'],
    'Own shelf life': ['Kendi raf ömrü', 'Termen propriu', 'Собствен срок'],
    'Allergens': ['Alerjenler', 'Alergeni', 'Алергени'],
    '✨ Suggest': ['✨ Öner', '✨ Sugerează', '✨ Предложи'],
    'Celery': ['Kereviz', 'Țelină', 'Целина'],
    'Cereals (gluten)': ['Tahıllar (gluten)', 'Cereale (gluten)', 'Зърнени (глутен)'],
    'Crustaceans': ['Kabuklular', 'Crustacee', 'Ракообразни'],
    'Eggs': ['Yumurta', 'Ouă', 'Яйца'],
    'Fish': ['Balık', 'Pește', 'Риба'],
    'Lupin': ['Acı bakla', 'Lupin', 'Лупина'],
    'Milk': ['Süt', 'Lapte', 'Мляко'],
    'Molluscs': ['Yumuşakçalar', 'Moluște', 'Мекотели'],
    'Mustard': ['Hardal', 'Muștar', 'Синап'],
    'Tree nuts': ['Sert kabuklu yemişler', 'Fructe cu coajă lemnoasă', 'Ядки'],
    'Peanuts': ['Yer fıstığı', 'Arahide', 'Фъстъци'],
    'Sesame': ['Susam', 'Susan', 'Сусам'],
    'Soya': ['Soya', 'Soia', 'Соя'],
    'Sulphites': ['Sülfitler', 'Sulfiți', 'Сулфити'],
    'May Contain': ['İçerebilir', 'Poate conține', 'Може да съдържа'],
    'e.g. Nuts, Sesame': ['ör. Fındık, Susam', 'ex. Nuci, Susan', 'напр. Ядки, Сусам'],
    'Custom Allergens': ['Diğer Alerjenler', 'Alți alergeni', 'Други алергени'],
    'e.g. Garlic': ['ör. Sarımsak', 'ex. Usturoi', 'напр. Чесън'],
    'Barcode': ['Barkod', 'Cod de bare', 'Баркод'],
    'Optional – scan to print this product': ['İsteğe bağlı – bu ürünü yazdırmak için tarayın', 'Opțional – scanează ca să tipărești acest produs', 'По избор – сканирайте, за да отпечатате продукта'],
    'Prep Guide': ['Hazırlık Kılavuzu', 'Ghid de preparare', 'Ръководство за подготовка'],
    'Method, temperatures, portion sizes…': ['Yöntem, sıcaklıklar, porsiyonlar…', 'Metodă, temperaturi, porții…', 'Метод, температури, порции…'],
    'Method, temperatures, portion sizes, photos references…': ['Yöntem, sıcaklıklar, porsiyonlar, fotoğraf referansları…', 'Metodă, temperaturi, porții, referințe foto…', 'Метод, температури, порции, снимки…'],
    'Delete product': ['Ürünü sil', 'Șterge produsul', 'Изтрий продукта'],
    'New Product': ['Yeni Ürün', 'Produs nou', 'Нов продукт'],
    'Edit Product': ['Ürünü Düzenle', 'Editează produsul', 'Редактирай продукта'],
    'Create product': ['Ürün oluştur', 'Creează produsul', 'Създай продукт'],
    'Save changes': ['Değişiklikleri kaydet', 'Salvează modificările', 'Запази промените'],
    'Enter a product name': ['Ürün adı girin', 'Introdu numele produsului', 'Въведете име на продукта'],
    'Product created': ['Ürün oluşturuldu', 'Produs creat', 'Продуктът е създаден'],
    'Saved': ['Kaydedildi', 'Salvat', 'Запазено'],
    'No allergens detected yet': ['Henüz alerjen algılanmadı', 'Încă nu s-au detectat alergeni', 'Все още не са открити алергени'],
    'Detected:': ['Algılanan:', 'Detectați:', 'Открити:'],
    'Suggested allergens already ticked': ['Önerilen alerjenler zaten işaretli', 'Alergenii sugerați sunt deja bifați', 'Предложените алергени вече са отметнати'],
    'No likely allergens found – check the recipe': ['Olası alerjen bulunamadı – tarifi kontrol edin', 'Nu s-au găsit alergeni probabili – verifică rețeta', 'Не са открити вероятни алергени – проверете рецептата'],
    'It will be removed from all devices at next sync.': ['Bir sonraki senkronizasyonda tüm cihazlardan kaldırılacak.', 'Va fi eliminat de pe toate dispozitivele la următoarea sincronizare.', 'Ще бъде премахнат от всички устройства при следващата синхронизация.'],
    'Delete': ['Sil', 'Șterge', 'Изтрий'],

    // profile form & PIN
    'New Profile': ['Yeni Profil', 'Profil nou', 'Нов профил'],
    'Edit Profile': ['Profili Düzenle', 'Editează profilul', 'Редактирай профила'],
    '4-digit PIN': ['4 haneli PIN', 'PIN din 4 cifre', '4-цифрен ПИН'],
    'Role': ['Rol', 'Rol', 'Роля'],
    'Remove profile': ['Profili kaldır', 'Elimină profilul', 'Премахни профила'],
    'Create profile': ['Profil oluştur', 'Creează profilul', 'Създай профил'],
    'Save': ['Kaydet', 'Salvează', 'Запази'],
    'PIN must be 4 digits': ['PIN 4 haneli olmalı', 'PIN-ul trebuie să aibă 4 cifre', 'ПИН кодът трябва да е 4 цифри'],
    'They will no longer be able to sign in on this site.': ['Bu şubede artık oturum açamayacak.', 'Nu se va mai putea conecta la această locație.', 'Вече няма да може да влиза в този обект.'],
    'Enter PIN for': ['PIN girin:', 'Introdu PIN-ul pentru', 'Въведете ПИН за'],
    'Wrong PIN': ['Yanlış PIN', 'PIN greșit', 'Грешен ПИН'],

    // wastage form
    'Product': ['Ürün', 'Produs', 'Продукт'],
    'Choose product…': ['Ürün seçin…', 'Alege produsul…', 'Изберете продукт…'],
    'Quantity': ['Miktar', 'Cantitate', 'Количество'],
    'Reason': ['Neden', 'Motiv', 'Причина'],
    'Damaged': ['Hasarlı', 'Deteriorat', 'Повреден'],
    'Spoiled / quality': ['Bozulmuş / kalite', 'Alterat / calitate', 'Развален / качество'],
    'Over-production': ['Fazla üretim', 'Supraproducție', 'Свръхпроизводство'],
    'Customer return': ['Müşteri iadesi', 'Retur client', 'Върнат от клиент'],
    'Temperature breach': ['Sıcaklık ihlali', 'Temperatură necorespunzătoare', 'Нарушена температура'],
    'Dropped / contaminated': ['Düşürülmüş / kirlenmiş', 'Scăpat / contaminat', 'Изпуснат / замърсен'],
    'Other': ['Diğer', 'Altele', 'Друго'],
    'Notes': ['Notlar', 'Note', 'Бележки'],
    'Optional': ['İsteğe bağlı', 'Opțional', 'По избор'],
    'Photo': ['Fotoğraf', 'Fotografie', 'Снимка'],
    'Photo (required)': ['Fotoğraf (zorunlu)', 'Fotografie (obligatoriu)', 'Снимка (задължително)'],
    'Retake photo': ['Yeniden çek', 'Refă fotografia', 'Нова снимка'],
    'Add photo': ['Fotoğraf ekle', 'Adaugă fotografie', 'Добави снимка'],
    'Estimated cost': ['Tahmini maliyet', 'Cost estimat', 'Приблизителна стойност'],
    'Choose a product': ['Bir ürün seçin', 'Alege un produs', 'Изберете продукт'],
    'Choose a reason': ['Bir neden seçin', 'Alege un motiv', 'Изберете причина'],
    'A photo is required by your manager': ['Müdürünüz fotoğraf istiyor', 'Managerul tău cere o fotografie', 'Мениджърът ви изисква снимка'],
    'Wastage logged': ['Fire kaydedildi', 'Deșeu înregistrat', 'Бракът е записан'],

    // print sheet
    'Print Label': ['Etiket Yazdır', 'Tipărește eticheta', 'Печат на етикет'],
    'View Prep Guide': ['Hazırlık Kılavuzunu Gör', 'Vezi ghidul de preparare', 'Виж ръководството'],
    'Create Prep Guide': ['Hazırlık Kılavuzu Oluştur', 'Creează ghid de preparare', 'Създай ръководство'],
    'Use First': ['Önce Kullan', 'Folosește primul', 'Използвай първо'],
    'Defrost': ['Çözdür', 'Decongelare', 'Размразяване'],
    'Single Height': ['Tek Yükseklik', 'Înălțime simplă', 'Единична височина'],
    'Double Height': ['Çift Yükseklik', 'Înălțime dublă', 'Двойна височина'],
    'Include Date': ['Tarihi ekle', 'Include data', 'Включи дата'],
    'Expiry Calculation': ['Son Kullanma Hesabı', 'Calcul expirare', 'Изчисляване на срока'],
    'Manual override': ['Elle ayar', 'Setare manuală', 'Ръчна настройка'],
    'Manual override…': ['Elle ayar…', 'Setare manuală…', 'Ръчна настройка…'],
    'Expiry Date': ['Son Kullanma Tarihi', 'Data expirării', 'Срок на годност'],
    'Edit': ['Düzenle', 'Editează', 'Редактирай'],
    'Batch Code': ['Parti Kodu', 'Cod lot', 'Партиден код'],
    'Save guide': ['Kılavuzu kaydet', 'Salvează ghidul', 'Запази ръководството'],
    'Prep guide saved': ['Hazırlık kılavuzu kaydedildi', 'Ghid de preparare salvat', 'Ръководството е запазено'],
    'No prep guide yet. Ask a manager to add one.': ['Henüz hazırlık kılavuzu yok. Bir müdürden eklemesini isteyin.', 'Încă nu există ghid de preparare. Roagă un manager să adauge unul.', 'Все още няма ръководство. Помолете мениджър да добави.'],
    'Misc Label': ['Diğer Etiket', 'Etichetă diversă', 'Друг етикет'],
    'Label text': ['Etiket metni', 'Text etichetă', 'Текст на етикета'],
    'e.g. Staff meal, Sample': ['ör. Personel yemeği, Numune', 'ex. Masa personalului, Mostră', 'напр. Храна за персонала, Мостра'],
    'Allergens (optional)': ['Alerjenler (isteğe bağlı)', 'Alergeni (opțional)', 'Алергени (по избор)'],
    'e.g. Milk, Eggs': ['ör. Süt, Yumurta', 'ex. Lapte, Ouă', 'напр. Мляко, Яйца'],
    'Enter label text': ['Etiket metni girin', 'Introdu textul etichetei', 'Въведете текст на етикета'],
    'Print Queue': ['Yazdırma Kuyruğu', 'Coadă de tipărire', 'Опашка за печат'],
    'waiting': ['bekliyor', 'în așteptare', 'изчаква'],
    'Queue is empty.': ['Kuyruk boş.', 'Coada este goală.', 'Опашката е празна.'],
    'Close': ['Kapat', 'Închide', 'Затвори'],
    'Cancel waiting': ['Bekleyenleri iptal et', 'Anulează cele în așteptare', 'Откажи чакащите'],
    'Label preview': ['Etiket önizlemesi', 'Previzualizare etichetă', 'Преглед на етикета'],
    'Identical copy queued': ['Aynı kopya kuyruğa eklendi', 'Copie identică adăugată în coadă', 'Идентично копие е добавено'],
    'Label roll running low – order more from Label Order': ['Etiket rulosu azalıyor – Etiket Siparişi’nden sipariş verin', 'Rola de etichete se termină – comandă din Comandă etichete', 'Ролката свършва – поръчайте от Поръчка на етикети'],
    'Built-in printer found – labels will print on this handheld': ['Dahili yazıcı bulundu – etiketler bu cihazdan yazdırılacak', 'Imprimantă integrată găsită – etichetele se vor tipări pe acest terminal', 'Открит е вграден принтер – етикетите ще се печатат на този терминал'],

    // lock, sync, connect
    'Check again': ['Tekrar kontrol et', 'Verifică din nou', 'Провери отново'],
    'Checking…': ['Kontrol ediliyor…', 'Se verifică…', 'Проверка…'],
    'Disconnect this handheld': ['Bu cihazın bağlantısını kes', 'Deconectează acest terminal', 'Прекъсни връзката на терминала'],
    'This handheld is locked: printing and syncing are paused until the licence is active.': ['Bu cihaz kilitli: lisans etkinleşene kadar yazdırma ve senkronizasyon durduruldu.', 'Acest terminal este blocat: tipărirea și sincronizarea sunt oprite până la activarea licenței.', 'Терминалът е заключен: печатът и синхронизацията са спрени, докато лицензът не бъде активен.'],
    'Buy a licence at': ['Lisans satın alın:', 'Cumpără o licență de pe', 'Купете лиценз на'],
    'or contact Proview:': ['veya Proview ile iletişime geçin:', 'sau contactează Proview:', 'или се свържете с Proview:'],
    'Licence active again – unlocked': ['Lisans yeniden etkin – kilit açıldı', 'Licența este din nou activă – deblocat', 'Лицензът е активен отново – отключено'],
    'Not connected – Menu → Settings → Connect to Proview Label': ['Bağlı değil – Menü → Ayarlar → Proview Label’a bağlan', 'Neconectat – Meniu → Setări → Conectează la Proview Label', 'Не е свързано – Меню → Настройки → Свържи с Proview Label'],
    'Demo data: live sync works in the Android app': ['Demo verisi: canlı senkronizasyon Android uygulamasında çalışır', 'Date demo: sincronizarea live funcționează în aplicația Android', 'Демо данни: синхронизацията работи в Android приложението'],
    'Please reconnect in Settings': ['Lütfen Ayarlar’dan yeniden bağlanın', 'Te rugăm să te reconectezi din Setări', 'Моля, свържете се отново от Настройки'],
    'Sign in': ['Oturum aç', 'Conectare', 'Вход'],
    'Signing in…': ['Oturum açılıyor…', 'Se conectează…', 'Влизане…'],
    'Password': ['Şifre', 'Parolă', 'Парола'],
    'Sign in with a back-office login (owner, admin or manager). Staff then use their PINs on this handheld.': ['Yönetim paneli hesabıyla oturum açın (sahip, yönetici veya müdür). Personel daha sonra bu cihazda kendi PIN’lerini kullanır.', 'Conectează-te cu un cont de back-office (proprietar, administrator sau manager). Apoi personalul folosește PIN-urile pe acest terminal.', 'Влезте с акаунт за бек офиса (собственик, администратор или мениджър). После персоналът използва своите ПИН кодове на терминала.'],
    'Use the same email as your Proview account. No password yet? Open label.proviewcrm.co.uk and use “Forgot password?” to set one.': ['Proview hesabınızdaki e-postayı kullanın. Şifreniz yok mu? label.proviewcrm.co.uk adresini açıp “Forgot password?” ile belirleyin.', 'Folosește același e-mail ca în contul Proview. Nu ai parolă? Deschide label.proviewcrm.co.uk și folosește „Forgot password?”.', 'Използвайте имейла от акаунта си в Proview. Нямате парола? Отворете label.proviewcrm.co.uk и използвайте „Forgot password?“.'],
    'Enter your email and password.': ['E-posta ve şifrenizi girin.', 'Introdu e-mailul și parola.', 'Въведете имейл и парола.'],
    'Set up this handheld': ['Bu cihazı kur', 'Configurează acest terminal', 'Настройка на терминала'],
    'Handheld name': ['Cihaz adı', 'Nume terminal', 'Име на терминала'],
    'Your name': ['Adınız', 'Numele tău', 'Вашето име'],
    'Your PIN': ['PIN’iniz', 'PIN-ul tău', 'Вашият ПИН'],
    '4 digits': ['4 hane', '4 cifre', '4 цифри'],
    'Finish setup': ['Kurulumu bitir', 'Finalizează configurarea', 'Завърши настройката'],
    'Saving…': ['Kaydediliyor…', 'Se salvează…', 'Запазване…'],
    'You\'ll be signed in on this handheld as a manager. Add other staff and their PINs in Manage Profiles or in the back-office.': ['Bu cihazda müdür olarak oturum açacaksınız. Diğer personeli ve PIN’lerini Profilleri Yönet’ten veya yönetim panelinden ekleyin.', 'Vei fi conectat pe acest terminal ca manager. Adaugă restul personalului și PIN-urile în Gestionează profilurile sau în back-office.', 'Ще бъдете вписани на терминала като мениджър. Добавете другия персонал и ПИН кодовете в Управление на профили или в бек офиса.'],
    'Enter your name.': ['Adınızı girin.', 'Introdu numele.', 'Въведете името си.'],
    'Choose a 4-digit PIN.': ['4 haneli bir PIN seçin.', 'Alege un PIN din 4 cifre.', 'Изберете 4-цифрен ПИН.'],
    'Someone at this site already uses that PIN. Pick another.': ['Bu şubede bu PIN kullanılıyor. Başka bir tane seçin.', 'Cineva de la această locație folosește deja acest PIN. Alege altul.', 'Някой в този обект вече използва този ПИН. Изберете друг.'],
    'Disconnect this handheld?': ['Bu cihazın bağlantısı kesilsin mi?', 'Deconectezi acest terminal?', 'Да се прекъсне ли връзката на терминала?'],
    'It stops syncing and goes back to demo data. Labels already sent stay in the back-office.': ['Senkronizasyon durur ve demo verisine döner. Gönderilmiş etiketler yönetim panelinde kalır.', 'Sincronizarea se oprește și revine la datele demo. Etichetele deja trimise rămân în back-office.', 'Синхронизацията спира и се връща към демо данни. Изпратените етикети остават в бек офиса.'],
    'Disconnected': ['Bağlantı kesildi', 'Deconectat', 'Връзката е прекъсната'],
    'Copy': ['Kopyala', 'Copiază', 'Копирай'],
    'Copied': ['Kopyalandı', 'Copiat', 'Копирано'],
    'Select and copy the text': ['Metni seçip kopyalayın', 'Selectează și copiază textul', 'Изберете и копирайте текста'],
    'Copy this and paste it into the back-office (Devices → Import from device).': ['Bunu kopyalayıp yönetim paneline yapıştırın (Devices → Import from device).', 'Copiază și lipește în back-office (Devices → Import from device).', 'Копирайте и поставете в бек офиса (Devices → Import from device).'],
    'Export failed': ['Dışa aktarma başarısız', 'Exportul a eșuat', 'Експортът не успя'],

    // updates
    'Checking for updates…': ['Güncellemeler kontrol ediliyor…', 'Se caută actualizări…', 'Проверка за обновления…'],
    'Update available': ['Güncelleme var', 'Actualizare disponibilă', 'Има обновление'],
    'Later': ['Sonra', 'Mai târziu', 'По-късно'],
    'Install now': ['Şimdi yükle', 'Instalează acum', 'Инсталирай сега'],
    'Downloading update…': ['Güncelleme indiriliyor…', 'Se descarcă actualizarea…', 'Изтегляне на обновлението…'],
    'Couldn\'t check for updates. Check the internet connection.': ['Güncellemeler kontrol edilemedi. İnternet bağlantısını kontrol edin.', 'Nu s-au putut verifica actualizările. Verifică conexiunea la internet.', 'Неуспешна проверка за обновления. Проверете интернет връзката.'],
    'Allow "Install unknown apps" for Proview Label, then tap Check for updates again': ['Proview Label için "Bilinmeyen uygulamaları yükle" iznini verin, sonra tekrar Güncellemeleri kontrol et’e dokunun', 'Permite „Instalare aplicații necunoscute” pentru Proview Label, apoi atinge din nou Caută actualizări', 'Разрешете „Инсталиране на неизвестни приложения“ за Proview Label и докоснете отново Проверка за обновления'],

    // days (used on screen next to dates)
    'Mon': ['Pzt', 'Lun', 'Пн'], 'Tue': ['Sal', 'Mar', 'Вт'], 'Wed': ['Çar', 'Mie', 'Ср'], 'Thu': ['Per', 'Joi', 'Чт'],
    'Fri': ['Cum', 'Vin', 'Пт'], 'Sat': ['Cmt', 'Sâm', 'Сб'], 'Sun': ['Paz', 'Dum', 'Нд']
  };

  // sentences with a number or a name in them: [pattern, [Türkçe, Română, Български]]; {1},{2}… are the matched parts (translated too when they can be)
  const PAT = [
    [/^(\d+) labels? printing$/, ['{1} etiket yazdırılıyor', '{1} etichete se tipăresc', '{1} етикета се печатат']],
    [/^\((\d+) labels? selected\)$/, ['({1} etiket seçildi)', '({1} etichete selectate)', '({1} избрани етикета)']],
    [/^(\d+) labels? selected$/, ['{1} etiket seçildi', '{1} etichete selectate', '{1} избрани етикета']],
    [/^(\d+) labels? in queue · (.+)$/, ['Kuyrukta {1} etiket · {2}', '{1} etichete în coadă · {2}', '{1} етикета в опашката · {2}']],
    [/^Printing (\d+) × (.+)$/, ['{1} × {2} yazdırılıyor', 'Se tipăresc {1} × {2}', 'Печат: {1} × {2}']],
    [/^Print (\d+)$/, ['{1} Yazdır', 'Tipărește {1}', 'Печат {1}']],
    [/^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) (\d.*)$/, ['{1} {2}', '{1} {2}', '{1} {2}']],
    [/^(Use by|Best before) (.+)$/, ['{1}: {2}', '{1} {2}', '{1}: {2}']],
    [/^Synced · (\d+) sent, (\d+) received$/, ['Senkronize edildi · {1} gönderildi, {2} alındı', 'Sincronizat · {1} trimise, {2} primite', 'Синхронизирано · {1} изпратени, {2} получени']],
    [/^Synced (.+)$/, ['Senkronize: {1}', 'Sincronizat {1}', 'Синхронизирано {1}']],
    [/^Last sync (.+)$/, ['Son senkronizasyon {1}', 'Ultima sincronizare {1}', 'Последна синхронизация {1}']],
    [/^(\d+) min ago$/, ['{1} dk önce', 'acum {1} min', 'преди {1} мин']],
    [/^(\d+) hr ago$/, ['{1} sa önce', 'acum {1} h', 'преди {1} ч']],
    [/^(\d+) days ago$/, ['{1} gün önce', 'acum {1} zile', 'преди {1} дни']],
    [/^Storage: (.+)$/, ['Saklama: {1}', 'Depozitare: {1}', 'Съхранение: {1}']],
    [/^Site: (.+)$/, ['Şube: {1}', 'Locație: {1}', 'Обект: {1}']],
    [/^Signed in as (.+)$/, ['{1} olarak oturum açıldı', 'Conectat ca {1}', 'Вписан като {1}']],
    [/^Connected to (.+)$/, ['{1} ile bağlandı', 'Conectat la {1}', 'Свързано с {1}']],
    [/^(\d+) labels · (\d+) print jobs$/, ['{1} etiket · {2} yazdırma işi', '{1} etichete · {2} tipăriri', '{1} етикета · {2} заявки за печат']],
    [/^(\d+) labels · storage (.+)$/, ['{1} etiket · saklama {2}', '{1} etichete · depozitare {2}', '{1} етикета · съхранение {2}']],
    [/^(\d+) labels · £(.+) ex\. VAT$/, ['{1} etiket · £{2} + KDV', '{1} etichete · £{2} fără TVA', '{1} етикета · £{2} без ДДС']],
    [/^(\d+) expired · (\d+) expiring within 24 hrs$/, ['{1} süresi geçmiş · {2} tanesi 24 saat içinde', '{1} expirate · {2} expiră în 24 de ore', '{1} изтекли · {2} изтичат до 24 ч']],
    [/^Expired – remove now \((\d+)\)$/, ['Süresi geçmiş – hemen kaldırın ({1})', 'Expirate – scoate acum ({1})', 'Изтекли – махнете веднага ({1})']],
    [/^Expiring within 24 hours \((\d+)\)$/, ['24 saat içinde sona erecek ({1})', 'Expiră în 24 de ore ({1})', 'Изтичат до 24 часа ({1})']],
    [/^In date \((\d+)\)$/, ['Süresi geçerli ({1})', 'În termen ({1})', 'В срок ({1})']],
    [/^(\d+) entries at this site$/, ['Bu şubede {1} kayıt', '{1} înregistrări la această locație', '{1} записа в този обект']],
    [/^(\d+) \(~(.+)\)$/, ['{1} (~{2})', '{1} (~{2})', '{1} (~{2})']],
    [/^([\d.]+) (weeks|days)$/, ['{1} {2}', '{1} {2}', '{1} {2}']],
    [/^(\+?)(\d+) (hours?|days?|months?)$/, ['{1}{2} {3}', '{1}{2} {3}', '{1}{2} {3}']],
    [/^(.+) \((\+\d+ \w+)\)$/, ['{1} ({2})', '{1} ({2})', '{1} ({2})']],
    [/^Own shelf life \((.+)\)$/, ['Kendi raf ömrü ({1})', 'Termen propriu ({1})', 'Собствен срок ({1})']],
    [/^Prep Guide – (.+)$/, ['Hazırlık Kılavuzu – {1}', 'Ghid de preparare – {1}', 'Ръководство – {1}']],
    [/^Delete (.+)\?$/, ['{1} silinsin mi?', 'Ștergi {1}?', 'Да се изтрие ли {1}?']],
    [/^Remove (.+)\?$/, ['{1} kaldırılsın mı?', 'Elimini {1}?', 'Да се премахне ли {1}?']],
    [/^No products in (.+)$/, ['{1} içinde ürün yok', 'Niciun produs în {1}', 'Няма продукти в {1}']],
    [/^Reprinting (.+) with today's date$/, ['{1} bugünün tarihiyle yeniden yazdırılıyor', 'Se retipărește {1} cu data de azi', '{1} се препечатва с днешна дата']],
    [/^No label or product found for (.+)$/, ['{1} için etiket veya ürün bulunamadı', 'Nicio etichetă sau produs pentru {1}', 'Няма етикет или продукт за {1}']],
    [/^Ticked (\d+): (.+) – check the recipe$/, ['{1} işaretlendi: {2} – tarifi kontrol edin', 'Bifați {1}: {2} – verifică rețeta', 'Отметнати {1}: {2} – проверете рецептата']],
    [/^You have the latest version \((.+)\)$/, ['En son sürüm sizde ({1})', 'Ai cea mai nouă versiune ({1})', 'Имате последната версия ({1})']],
    [/^Version (.+) is ready \(you have (.+)\)\.$/, ['{1} sürümü hazır (sizdeki: {2}).', 'Versiunea {1} este gata (ai {2}).', 'Версия {1} е готова (имате {2}).']],
    [/^Paired: (.+)$/, ['Eşleştirildi: {1}', 'Asociat: {1}', 'Сдвоен: {1}']],
    [/^Printer: (.+)$/, ['Yazıcı: {1}', 'Imprimantă: {1}', 'Принтер: {1}']],
    [/^Camera unavailable: (.+)$/, ['Kamera kullanılamıyor: {1}', 'Camera nu este disponibilă: {1}', 'Камерата не е достъпна: {1}']],
    [/^Update failed: (.+)$/, ['Güncelleme başarısız: {1}', 'Actualizarea a eșuat: {1}', 'Обновлението не успя: {1}']],
    [/^(.+) – still locked$/, ['{1} – hâlâ kilitli', '{1} – încă blocat', '{1} – все още заключено']],
    [/^UK-based support, (.+)\. Messages outside these hours are picked up the next working day\.$/, ['Birleşik Krallık merkezli destek, {1}. Bu saatler dışındaki mesajlar bir sonraki iş günü yanıtlanır.', 'Asistență din Marea Britanie, {1}. Mesajele din afara programului sunt preluate în următoarea zi lucrătoare.', 'Поддръжка от Великобритания, {1}. Съобщенията извън работно време се обработват на следващия работен ден.']],
    [/^(\d+)% \(charging\)$/, ['%{1} (şarj oluyor)', '{1}% (se încarcă)', '{1}% (зарежда се)']]
  ];

  let lang = 'en';
  try { lang = localStorage.getItem(KEY) || 'en'; } catch (e) {}
  if (!LANGS.some((l) => l.code === lang)) lang = 'en';

  function tx(s) {
    if (lang === 'en' || !s) return null;
    const i = COL[lang];
    if (Object.prototype.hasOwnProperty.call(D, s)) return D[s][i];
    for (const [re, t] of PAT) {
      const m = s.match(re);
      if (m) return t[i].replace(/\{(\d)\}/g, (_, n) => { const g = m[n] || ''; const v = g && g !== s ? tx(g) : null; return v != null ? v : g; });
    }
    // "A · B · C" lines: translate each part that we know
    if (s.includes(' · ')) {
      let hit = false;
      const out = s.split(' · ').map((p) => { const v = tx(p); if (v != null) { hit = true; return v; } return p; });
      if (hit) return out.join(' · ');
    }
    return null;
  }

  // never translate the label preview, the print animation, names the business typed in, or text being edited
  const SKIP = '.lab,.paper,[data-notr],[contenteditable="true"],textarea,script,style,svg';
  const NAME = '.tile,.pn,.ah>span,.who b,.users button';
  const skipEl = (el) => !el || !!el.closest(SKIP);
  const REC = new WeakMap();   // text node -> { o: English original, t: what we last wrote }

  function doText(n) {
    const el = n.parentElement;
    if (skipEl(el) || el.matches(NAME)) return;
    const cur = n.nodeValue;
    let r = REC.get(n);
    if (!r || cur !== r.t) { r = { o: cur, t: cur }; REC.set(n, r); }
    const m = r.o.match(/^(\s*)([\s\S]*?)(\s*)$/);
    if (!m[2]) return;
    const v = tx(m[2]);
    const nv = v != null ? m[1] + v + m[3] : r.o;
    // a <select> option with no value uses its text as the value: keep the English value
    if (v != null && el.tagName === 'OPTION' && !el.hasAttribute('value')) el.setAttribute('value', m[2]);
    r.t = nv;
    if (nv !== cur) n.nodeValue = nv;
  }
  const ATTRS = ['placeholder', 'aria-label', 'title', 'alt'];
  function doAttrs(el) {
    if (!el.__pvlA) el.__pvlA = {};
    ATTRS.forEach((a) => {
      if (!el.hasAttribute(a)) return;
      const cur = el.getAttribute(a); let r = el.__pvlA[a];
      if (!r || cur !== r.t) r = el.__pvlA[a] = { o: cur, t: cur };
      const v = tx(r.o.trim()); const nv = v != null ? v : r.o;
      r.t = nv; if (nv !== cur) el.setAttribute(a, nv);
    });
  }
  function walk(root) {
    if (!root) return;
    if (root.nodeType === 3) return doText(root);
    if (root.nodeType !== 1 || skipEl(root)) return;
    doAttrs(root);
    const w = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => (n.nodeType === 1 && n.matches(SKIP) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT)
    });
    let n; while ((n = w.nextNode())) { if (n.nodeType === 3) doText(n); else doAttrs(n); }
  }

  let ROOT = null, busy = false;
  function start(root) {
    ROOT = root; document.documentElement.lang = lang === 'en' ? 'en-GB' : lang;
    walk(root);
    new MutationObserver((ms) => {
      if (busy) return; busy = true;
      try {
        ms.forEach((m) => {
          if (m.type === 'characterData') doText(m.target);
          else if (m.type === 'attributes') { if (m.target.nodeType === 1 && !skipEl(m.target)) doAttrs(m.target); }
          else m.addedNodes.forEach(walk);
        });
      } finally { busy = false; }
    }).observe(root, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ATTRS });
  }
  function set(code) {
    if (!LANGS.some((l) => l.code === code)) return;
    lang = code; try { localStorage.setItem(KEY, code); } catch (e) {}
    document.documentElement.lang = code === 'en' ? 'en-GB' : code;
    if (ROOT) walk(ROOT);
  }

  window.PVLi18n = { LANGS, FLAGS, start, set, lang: () => lang, t: (s) => { const v = tx(s); return v != null ? v : s; } };
})();
