# UstaTeklif v6 — Fotoğraflı ilanlar

- Müşteri yeni ilana en fazla 5 fotoğraf ekleyebilir.
- JPEG, PNG ve WebP kabul edilir; fotoğraf başına üst sınır 8 MB'dir.
- Fotoğraflar Supabase Storage içindeki özel `listing-photos` bucket'ında tutulur.
- Dosya yolları `listing_photos` tablosunda tutulur; görüntüler istemciye süreli imzalı URL ile açılır.
- Yalnızca oturum açmış kullanıcılar ilan fotoğraflarını okuyabilir; yükleme/silme yolu kullanıcı kimliği ile sınırlandırılmıştır.
- Ustalar açık ilan kartlarında fotoğrafları görebilir; müşteri de kendi ilanında görür.

Mevcut kurulumda yalnızca `FOTOGRAF-GUNCELLEMESI.sql` dosyasını bir kez çalıştırın. Yeni kurulumda `supabase-kurulum.sql` yeterlidir.
