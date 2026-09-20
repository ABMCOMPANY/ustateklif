# UstaTeklif v5 — Konum ve hizmet bölgesi

Bu sürüm ilan konumunu `il / ilçe / mahalle` olarak ayrı alanlarda saklar. Usta profilinde hizmet verilen il ve ilçeler tutulur. Usta açık ilan ekranı, profilinde konum tanımlıysa yalnızca eşleşen ilanları gösterir.

## Mevcut projeyi yükseltme
1. Supabase > SQL Editor bölümünde `KONUM-GUNCELLEMESI.sql` dosyasını bir kez çalıştır.
2. Yeni web dosyalarını yayınla.
3. Usta hesapları **Hesabım** bölümünden hizmet verdiği il ve ilçeleri seçsin/yazsın.

Eski ilanların `area` alanı korunur. Eski ilanlar yapılandırılmış konuma sahip olmadığı için, konum filtresi aktif bir usta hesabında görünmeyebilir; yeni ilanlar tam yapılandırılmış konumla kaydedilir.

Not: İl listesi uygulamaya gömülüdür. İlçe ve mahalle alanları şimdilik serbest metindir; veritabanı şeması bunları ayrı tuttuğu için daha sonra resmi/harici idari bölge veri setiyle açılır listelere geçirilebilir.
