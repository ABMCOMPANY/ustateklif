# UstaTeklif kurulum rehberi (telefondan)

Toplam süre: yaklaşık 20-30 dakika. Bilgisayar gerekmez.

## Dosyalar

- `index.html`: uygulamanın kendisi
- `config.js`: veritabanı bağlantı bilgileri (başta boş)
- `manifest.webmanifest`, `sw.js`, `icon-*.png`: ana ekrana eklemek için gerekenler
- `supabase-kurulum.sql`: sıfırdan kurulum için veritabanı tabloları ve güvenlik kuralları
- `GUVENLIK-GUNCELLEMESI.sql`: daha önce kurulmuş veritabanını güvenli iş akışına yükseltir

## 1. Veritabanı (Supabase, ücretsiz)

1. supabase.com adresine git, "Start your project" de ve Google veya GitHub ile giriş yap.
2. "New project" oluştur. Ad: ustateklif. Veritabanı şifresini not al. Bölge olarak sana yakın olanı seç (ör. Frankfurt). Hazır olması 1-2 dakika sürer.
3. Sol menüden **SQL Editor** > **New query** aç. `supabase-kurulum.sql` dosyasının tamamını kopyalayıp yapıştır ve **Run** de. "Success" yazısını görmelisin.
4. **Authentication** bölümünde e-posta girişini bul (Sign In / Providers > Email). Test aşamasında **Confirm email** seçeneğini kapat ve kaydet. Açık kalırsa her kayıtta e-posta doğrulaması gerekir.
5. **Project Settings** > **API Keys** (veya Data API) bölümünden iki şeyi not al:
   - Project URL (https://xxxx.supabase.co gibi)
   - anon / publishable (genel) anahtar

   Gizli anahtarı (service_role veya secret) kimseyle paylaşma ve uygulamaya yazma.

### Mevcut kurulumu güncelliyorsan

Daha önce `supabase-kurulum.sql` çalıştırdıysan, yeni veritabanı kurma. Supabase **SQL Editor** içinde yalnızca `GUVENLIK-GUNCELLEMESI.sql` dosyasını bir kez çalıştır. Ardından güncel `index.html` dosyasını yayınla. Bu güncelleme usta seçme ve işi tamamlama işlemlerini sunucu tarafında doğrular.

## 2. Yayınlama (GitHub Pages, ücretsiz)

1. github.com'da hesap aç veya giriş yap.
2. **New repository** ile yeni depo oluştur. Ad: ustateklif. **Public** seç. Oluştur.
3. Depo sayfasında **uploading an existing file** bağlantısına dokun. Bu klasördeki tüm dosyaları seç (`index.html`, `config.js`, `manifest.webmanifest`, `sw.js`, üç `icon-*.png`). SQL ve bu rehberi yüklemene gerek yok. **Commit changes** de.
4. **Settings** > **Pages** bölümüne git. Source olarak **Deploy from a branch**, branch olarak **main** ve **/ (root)** seç, kaydet.
5. 1-2 dakika sonra adresin hazır olur: `https://KULLANICIADIN.github.io/ustateklif/`

## 3. İlk açılış

1. Adresi telefonunda aç. Uygulama senden proje adresini ve genel anahtarı ister. Yapıştırıp kaydet. (Bilgiler sadece o telefonda saklanır.)
2. **Kayıt ol** ile hesap aç ve ilan açmayı dene.
3. Herkesin ek bir şey girmeden kullanabilmesi için GitHub'da `config.js` dosyasını aç, kalem simgesiyle düzenle, iki satırı doldur ve commit et.

## 4. Nasıl test edilir

Kendi kendine test için iki hesap aç (iki farklı e-posta):

- Hesap A: **Müşteri** modunda ilan açar.
- Hesap B: **Usta** modunda o ilana teklif verir.
- Hesap A geri girip teklifi seçer, mesajlaşır ve puan verir.

İki hesabı aynı telefonda denemek için biri normal sekmede, biri gizli sekmede olsun. Hesap değiştirmek için sağ üstteki daire > Çıkış yap.

## 5. Uygulama gibi ekle

- Android (Chrome): menü (⋮) > **Uygulamayı yükle** veya **Ana ekrana ekle**
- iPhone (Safari): **Paylaş** > **Ana Ekrana Ekle**

## Bilmen gerekenler

- Bu sürümde her kullanıcı hem müşteri hem usta olabilir; üstteki düğmeyle mod değiştirilir. Usta uzmanlığı: daire > Hesabım.
- Fiyatlar sadece ilan sahibine ve teklifi veren ustaya görünür. Diğer ustalar sadece kaç teklif geldiğini görür.
- Mesajlaşma yalnızca ilan sahibi ile seçilen usta arasında açılır.
- Ödeme, kimlik doğrulama, bildirim (telefona push) ve harita henüz yok. Şikayet/engelleme ve yönetici paneli de yok. Gerçek kullanıcıya açmadan önce bunları konuşalım.
- Supabase ücretsiz katmanı başlangıç için yeterlidir; kullanım artınca ücretli plana geçmen gerekebilir.
