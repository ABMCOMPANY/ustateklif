# UstaTeklif v9 — Yönetici Paneli

Mevcut v8 projenizde `YONETICI-PANELI-GUNCELLEMESI.sql` dosyasını Supabase SQL Editor'da bir kez çalıştırın.

İlk yöneticiyi tanımlamak için dosyanın en altındaki örnek INSERT komutunda e-posta adresini kendi kayıtlı yönetici hesabınızla değiştirip ayrıca çalıştırın. Yönetici yetkisi tarayıcıda tutulmaz; `admin_users` tablosu ve `is_admin()` kontrolü sunucu tarafındadır.

Panel: Hesabım > Yönetici paneli. Burada toplam kullanıcı/açık ilan/tamamlanan iş/açık şikâyet sayıları, şikâyet kuyruğu, kimlik doğrulama onayı ve hesap askıya alma/açma işlemleri bulunur.

Not: Askıya alınan hesap uygulama arayüzünde işlem yapamaz. Üretime çıkmadan önce Supabase Auth tarafında da ban/oturum iptali uygulayan bir Edge Function veya sunucu yönetim katmanı eklenmesi önerilir; tarayıcıya service-role anahtarı kesinlikle konulmamalıdır.
