# UstaTeklif v4 — Usta profili

Bu sürüm usta profilini teklif kararının bir parçası haline getirir.

## Eklenenler
- Usta/işletme adı ve kısa uzmanlık başlığı
- 600 karakterlik tanıtım metni
- Virgülle girilebilen hizmetler
- Virgülle girilebilen hizmet bölgeleri
- Teklif kartında profil özeti
- Tamamlanan iş sayısı ve ortalama müşteri puanı
- Profil tamamlanma göstergesi
- Sahte doğrulama rozeti yok: kimlik/telefon doğrulaması eklenene kadar uygulama böyle bir iddiada bulunmaz

## Mevcut projeyi yükseltme
1. Supabase > SQL Editor'a gir.
2. `USTA-PROFILI-GUNCELLEMESI.sql` dosyasını çalıştır.
3. Ardından v4 web dosyalarını yayınla.

Yeni kurulum yapıyorsan güncel `supabase-kurulum.sql` zaten yeni profil alanlarını içerir.
