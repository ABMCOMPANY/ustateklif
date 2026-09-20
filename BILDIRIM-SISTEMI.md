# UstaTeklif v7 — Bildirim sistemi

Bu sürüm uygulama içi bildirim merkezi ekler.

- Müşteri yeni teklif geldiğinde bildirim alır.
- Seçilen usta teklifinin seçildiğini görür.
- Mesajlaşmadaki diğer taraf yeni mesaj bildirimi alır.
- Profilinde hizmet şehri, hizmet ilçeleri ve en az bir hizmet tanımlayan ustalar, bölgelerine yeni ilan geldiğinde bildirim alır.
- Üst menüde okunmamış bildirim sayacı bulunur.
- Bildirimler tek tek açılabilir veya topluca okundu yapılabilir.
- Bildirim satırları RLS ile yalnızca bildirimin sahibi tarafından okunabilir/güncellenebilir.

## Mevcut kurulum
Supabase > SQL Editor içinde `BILDIRIM-GUNCELLEMESI.sql` dosyasını bir kez çalıştırın. Ardından yeni web dosyalarını yayınlayın.

Not: Bu sürüm uygulama içi gerçek zamanlı bildirimdir. Telefon kapalıyken gelen sistem push bildirimi değildir; web push için ayrıca push aboneliği ve sunucu/Edge Function altyapısı gerekir.
