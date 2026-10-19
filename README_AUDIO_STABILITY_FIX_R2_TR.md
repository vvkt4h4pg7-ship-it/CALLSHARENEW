# CALLSHARE Audio Stability Fix R2 — TEST ADAYI

## Amaç
Bu ayrı test kopyası, mevcut iPhone IPA'sını ve J7 üzerinde çalışan `j7_wifi_voice_core_R2_STABILITY_R1` ikilisini değiştirmeden ikinci aramada sessizlik sorununu hedefler.

## Kaynak bulgularıyla eşleştirilmiş değişiklikler

1. **Oynatma kuyruğu taşması:** Telefonun kurulu R2 IPA'sı `pending=4` olduğunda `playerNode.stop()` + `reset()` ile kuyruğu temizliyordu. Sağlanan yeni kaynak projesindeki R3 davranışı bu durumda gelen kareyi atlıyor. Bu aday, R3'ün kuyruk yaklaşımını korur.
2. **Oynatma ilerleme watchdog'u:** `AVAudioEngine.isRunning` ve `AVAudioPlayerNode.isPlaying` true görünse bile `.dataPlayedBack` callback'leri durursa R3'te pending sayaç 4'te kalıp süresiz kare düşürebilir. Bu aday, kuyruk dolu ve 300 ms boyunca oynatma tamamlanması görülmemişse ses grafiğini tek kontrollü kurtarma denemesine alır. Olağan anlık dolulukta oynatıcıyı durdurup sıfırlamaz.
3. **Çağrı başına epoch:** Her açılışta playback epoch ve pending sayaçları sıfırlanır; önceki çağrının gecikmiş callback'leri yeni çağrının sayaçlarını değiştiremez.
4. **Boşta iPhone audio parse gate:** BLE + CallKit + GSM + VOICE_OPEN koşulu sağlanıp ses motoru başarıyla başladığında iPhone tarafında UDP ses karelerinin yeniden birleştirilmesi/oynatma motoruna gönderilmesi açılır. Çağrı sonu, VOICE_CLOSE veya CallKit audio deactivate ile kapatılır. UDP soketi bağlı kalır ve datagram sayacı düşük sıklıkla artabilir; bu işlem tek başına J7 Core'un gönderimini durdurmaz.
5. **UDP RX socket recovery:** Mevcut çalışma ağacında kaldırılmış olan `recvfrom()` hata sonrası yeniden bind mekanizması geri eklendi. `errno=57` gibi terminal hatadan sonra alıcı dead fd'yi açık sayıp sonsuza dek durmuş kalmamalı.
6. **Kuyruk logları:** `PLAYBACK STALL`, `PLAYBACK DROP`, `RX DELIVERY GATE` ve `RX stream state reset` kayıtları ile sessizliğin yeniden oluşması daha kolay ayrıştırılabilir.
7. **CallKit deactivation çakışması:** AppModel zaten arama bitiminde sesi kapattığı için `reportRemoteEnd` ve `CXEndCallAction` içindeki ikinci, kimliksiz `onAudioDeactivated` çağrıları kaldırıldı. `didDeactivate` geldiğinde yeni bir CallKit UUID'si hâlen canlıysa geç gelen eski çağrı bildirimi yeni oturumu kapatamaz; bu durum ayrı loglanır.
8. **Ayrı bundle ID:** `com.ugur.callshare.audiofixr2` kullanır; mevcut `com.ugur.callshare` uygulamasının üstüne kurulmak üzere tasarlanmamıştır.

## J7 Core bulgusu — değiştirilmedi
`j7_wifi_voice_core_R2_STABILITY_R1.cpp` içinde ana capture/TX döngüsü `while (g_run)` boyunca `read_capture_block()` ve üç parçalı UDP `sendto()` çağrılarını çalıştırıyor. GSM/VOICE_OPEN durumuna bağlı bir TX gate yok. Dolayısıyla çağrı yokken iPhone'da `RX DATAGRAM` sayacının artması mevcut Core davranışıyla uyumludur. **Core kaynak kodu ve binary bu paket içinde değiştirilmemiştir.** Gerçek anlamda J7 capture/TX durdurma için Android BLE köprüsünün çağrı durumu sinyalinin Core'a güvenli şekilde taşınması gerekir; bunu bu iOS testine karıştırmadık.

## Test sırası

1. Bu ZIP'i ayrı bir klasöre çıkarıp Xcode'da açın.
2. Signing bölümünde kendi Development Team'inizi seçin. Bundle ID'nin `com.ugur.callshare.audiofixr2` olduğunu doğrulayın.
3. Önce derleyin. Bu ortamda Xcode/iOS SDK bulunmadığından IPA burada derlenmedi; gerçek cihaz testi yapılmadı.
4. Mevcut CALLSHARE kurulumunu kaldırmayın. Yeni test uygulamasını ayrı uygulama olarak yükleyin.
5. J7'de çalışan Core'u durdurmayın, yeniden başlatmayın veya üzerine yazmayın.
6. İlk aramayı yanıtlayın, kapatın, ikinci aramayı yanıtlayın; en az 3 ardışık çağrıyla test edin.
7. Sessizlik oluşursa `PLAYBACK STALL`, `PLAYBACK DROP`, `R3 RX PCM`, `UDP RX ERROR`, `UDP RX RECOVERY`, `AUDIO ACTIVATED/DEACTIVATED` kayıtlarını gönderin.

## Geri dönüş
Test uygulaması ayrı bundle kimliğine sahiptir. Sorun olursa yalnızca test uygulamasını kapatın/kaldırın ve eski CALLSHARE uygulamasını kullanmaya devam edin. J7 Core'a müdahale yok.

## Sınırlar
Bu bir **derlenmemiş test kaynak adayıdır**, doğrulanmış son çözüm değildir. Xcode derlemesi ve gerçek çağrı testi geçmeden bunu çalışan sürüm olarak kullanmayın.
