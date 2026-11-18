# xaosControl: релизы

Здесь лежат готовые сборки панели xaosControl для Ubuntu 24.04 и её установщик. Исходного кода в этом репозитории нет.

## Установка

```sh
curl -fsSL https://get.xaos.cc/install.sh | sudo bash -s -- --host <адрес> --email <почта> --allow <ваш IP>
```

Та же команда обновляет уже установленную панель: настройки и данные остаются на месте.

## Что здесь лежит

- `install.sh` — установщик. Он скачивает архив последней версии, проверяет его подпись и ставит панель.
- `latest.txt` — номер последней версии.
- В разделе [Releases](../../releases) — архивы `xaoscc_<версия>_linux_amd64.tar.gz` и `xaoscc_<версия>_linux_arm64.tar.gz`, рядом с каждым его подпись `.minisig`.

## Подпись

Каждый архив подписан ключом [minisign](https://jedisct1.github.io/minisign/). Установщик проверяет подпись сам и ничего не ставит, если она не сходится. С версии 1.0.4 ключей два, подходит любой:

- `DD6B33495157150E`, им подписываются выпуски начиная с 1.0.5:

  ```sh
  minisign -Vm xaoscc_v1.0.5_linux_amd64.tar.gz -P RWQOFVdRSTNr3Z+m0WIuOipgB466AieHv9uC6Ka00h2arvd4nACbccxR
  ```

- `5357BA8306410571`, ключ владельца, им подписаны 1.0.0–1.0.4:

  ```sh
  minisign -Vm xaoscc_v1.0.4_linux_amd64.tar.gz -P RWRxBUEGg7pXUzp95Z1flPPOdPtt1cX9Kq7fc9rjF4nP+8KlBqJGb3gw
  ```

Поставить панель можно и без скачивания установщика: распаковать проверенный архив и запустить `install.sh` из него.
