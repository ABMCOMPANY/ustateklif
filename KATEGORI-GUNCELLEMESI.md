# UstaTeklif v3 — Hizmet kategorileri

Bu sürümde veritabanı değişikliği gerekmez. `category` alanı metin olduğu için yeni kategoriler mevcut tabloyla uyumludur.

## Eklenen yapı
- Ev & Tadilat: Boya & Badana, Su Tesisatı, Elektrik, Mobilya & Montaj, Fayans & Seramik
- Teknik Servis: Klima, Beyaz Eşya, Kombi & Isıtma, TV & Elektronik
- Oto & Yol: Lastik & Jant, Oto Servis
- Ev & Yaşam: Temizlik, Nakliyat, Bahçe & Peyzaj
- Diğer Hizmet

Her kategorinin altında ilan verirken seçilebilen hizmet/alt kategori seçenekleri vardır. Yeni ilan ekranına kategori ve hizmet araması da eklendi. Eski ilanların kategori anahtarları korunmuştur; mevcut veriler çalışmaya devam eder.

## Yayına alma
Mevcut v2 kurulumunun üzerine `index.html` ve `sw.js` dosyalarını yükle. Diğer dosyaları da aynı paketten kullanabilirsin. Bu güncelleme için ek SQL çalıştırman gerekmez.
