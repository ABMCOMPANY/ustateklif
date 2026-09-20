# UstaTeklif v8 — Güven ve moderasyon

Bu sürüm şikâyet, kullanıcı engelleme ve doğrulama rozetlerinin güvenli veri modelini ekler.

## Mevcut projeyi yükseltme
Supabase > SQL Editor içinde `GUVEN-MODERASYON-GUNCELLEMESI.sql` dosyasını **bir kez** çalıştırın. Ardından v8 web dosyalarını yayınlayın.

## Telefon doğrulaması
`phone_verified` kullanıcı tarafından düzenlenemez. `sync_my_verification()` yalnızca Supabase Auth içindeki `phone_confirmed_at` değerine bakar. Gerçek SMS OTP akışını kullanmak için Supabase Dashboard'da telefon sağlayıcısı/SMS provider ayrıca yapılandırılmalıdır. Bu paket doğrulanmamış telefonu doğrulanmış göstermez.

## Kimlik doğrulaması
`identity_verified` normal kullanıcı tarafından değiştirilemez. Yalnızca güvenilir yönetim/service-role sürecinden verilmelidir. Uygulama bu alan true olmadıkça kimlik doğrulandı rozeti göstermez.

## Şikâyetler
Kullanıcılar en az 10 karakterlik bir gerekçeyle şikâyet oluşturabilir. Şikâyetler diğer uygulama kullanıcılarına listelenmez; yönetim/service-role tarafından incelenmek üzere `reports` tablosunda tutulur.

## Engelleme
Engellenen iki kullanıcı arasında yeni teklif ve mesaj etkileşimi RLS seviyesinde kesilir. Usta tarafında engellenen müşterilerin açık ilanları da gizlenir.
