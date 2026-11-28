# kokoro-xray

<p align="center">
  <img src="docs/img/kokoro-neko.jpg" alt="kokoro-xray" width="360">
</p>

Xray のエッジ/エグジット構築用の小さなシェルマネージャーだにゃ〜

スクリプトは状態を JSON で保持し、`jq` で設定をレンダリングし、リロード前に検証を行い、大きなフレームワークへの依存をさけているにゃ。

[English](README.md) | [日本語](README.ja.md)

## Cloudflare Tunnel と WARP

エッジの `argo` は VLESS Encryption を有効にした XHTTP をループバックで受けます。`warp` はエッジまたは出口の指定した通信を Xray の MASQUE で送ります。どちらも初期状態では無効で、個別に使用できます。

```sh
kokoro-xray argo setup --mode named --hostname tunnel.example.org --token-file /root/tunnel.token
kokoro-xray argo status
kokoro-xray link --json argo --cf-ip 198.51.100.10
kokoro-xray warp setup --import-usque /root/usque.json --transport h3 --route-presets ai,streaming,google
kokoro-xray warp test
```

ホスト名と接続先 IP は実際の値に置き換えてください。`--cf-ip` は接続先だけを変更し、SNI と Host は公開ホスト名を使います。Cloudflare 管理画面の接続先は `http://127.0.0.1:18080` です。cloudflared から Cloudflare までは既定で QUIC、ローカルの平文 HTTP 接続は HTTP/1.1 です。UDP が使えない場合は `--protocol http2` を選べます。トンネルには送信先ポート 7844 を許可してください。

`argo setup --mode quick` は一時ホスト名を発行します。再起動後は `argo status` と `link --json argo` で更新してください。常用には名前付きトンネルを使用してください。`--tunnel-only` は公開リスナーと Hysteria2 を停止します。既存のファイアウォール許可は別途確認してください。`argo off` はサービスと環境ファイルを削除し、`argo uninstall` は保存済みトークンも消去します。

WARP には登録済み P-256 鍵と割当アドレスが必要です。`--import-usque` の代わりに `--private-key-file` と `--addresses` を指定できます。`--public-key` または `--cert-pin` で接続先を固定してください。指定せず鍵を初回取得する場合は別経路で検証してください。`warp fetch-pubkey` は鍵が変わると停止します。Xray 26.11.9 の送信 MTU は 1280 固定です。

既定の H3 は対象ドメインだけを WARP に送ります。`--transport h2` と `warp.finalmask.enabled` で TCP 断片化を使えます。`warp.custom_domains`、`warp.ipv4_via_warp` は `config.json` で設定して `kokoro-xray apply` を実行してください。`--route-mode all` では未一致の通信も対象になります。ペアリング済みエッジは既定経路に WireGuard 出口を使います。`warp on|off` で切り替え、`warp test --speed` は WARP と直接回線で各 20 MB を転送します。

## サポートモード

- エッジ単一ノード: VLESS XHTTP REALITY、TLS、または両方
- エッジ + エグジット: エッジが WireGuard を経てトラフィックをエグジットに転送
- TLS エッジ: Caddy が ACME と HTTPS ルーティングを処理
- REALITY エッジ: Xray がパブリックの `:443` を直接提供

## 要件

- Debian または Ubuntu
- ルート権限
- 公開リスナーを使うエッジでは `443/tcp` を開放
- TLS エッジノードでは ACME のため `80/tcp` を開放
- エッジ + エグジットを使う場合はエグジットノードの UDP ポートを開放 (デフォルト `51820/udp`)

## インストール

レビュー済みのインストーラーコミットは
`4fb7bdc1b4dd354bd52eea498a5eab3bb7d631bc` にゃ。この不変リビジョンから
ブートストラップを取得し、同じ SHA をブートストラップに渡すにゃ:

```bash
commit=4fb7bdc1b4dd354bd52eea498a5eab3bb7d631bc
curl -fsSL "https://raw.githubusercontent.com/takashi728/kokoro-xray/${commit}/install.sh" \
    -o /tmp/kokoro-install.sh
sudo env KOKORO_REPO_COMMIT="$commit" bash /tmp/kokoro-install.sh
```

インストーラーは、実インストールを置き換える前に、ステージ済みリポジトリが
このコミットと完全に一致することを検証するにゃ。一致しなければ起動前に
中止するにゃ。

エッジをセットアップにゃ:

```bash
sudo kokoro-xray edge
```

エグジットをセットアップにゃ:

```bash
sudo kokoro-xray exit
```

## 更新

ふつうの更新では既存の状態を保持するにゃ。**インストール**にある
レビュー済みの不変ブートストラップを取得して実行した後:

```bash
sudo kokoro-xray apply
```

クリーンな再インストールは `/opt/kokoro-xray` を削除し、`~/.kokoro-xray` は保持するにゃ:

```bash
sudo kokoro-xray reinstall
sudo kokoro-xray apply
```

コミット固定を導入する前のインストールには
`~/.kokoro-xray/installed-commit` がないにゃ。`reinstall` を使う前に、
固定済みブートストラップを一度だけ再実行してねにゃ。ブートストラップが
ノード状態を変更せずに信頼済みリビジョンを記録するにゃ。

## 基本フロー

単一エッジ:

```bash
sudo kokoro-xray edge
sudo kokoro-xray apply
kokoro-xray link
kokoro-xray status
```

エッジ + エグジット:

```bash
# エグジット上で
sudo kokoro-xray exit

# エッジ上で
sudo kokoro-xray edge
sudo kokoro-xray pair
sudo kokoro-xray apply

# エグジットに戻り、プロンプトでエッジのピア情報を貼り付け
sudo kokoro-xray pair
sudo kokoro-xray apply
```

## クライアント出力

標準の共有リンクにゃ:

```bash
kokoro-xray link
```

完全な JSON インポートに対応するクライアント向け TLS XHTTP JSON エクスポート:

```bash
kokoro-xray link --json tls
```

TLS モードでは、クライアントアプリが URL サブスクリプションから高度な XHTTP 設定を保持できない場合は JSON エクスポートを使ってねにゃ。

## コマンド

| コマンド | 説明 |
| --- | --- |
| `edge [--keep-secrets]` | エッジノードをインストールまたは更新 |
| `exit [--keep-secrets]` | エグジットノードをインストールまたは更新 |
| `apply` | 設定をレンダリング、検証し、サービスをリロード |
| `pair` | エッジ/エグジット間の WireGuard ピア情報を交換 |
| `link [--json tls]` | クライアントリンクまたは Xray TLS JSON プロファイルを出力 |
| `status` | サービスと設定のステータスを表示 |
| `validate` | レンダリングされた設定を検証 |
| `geodata` | ジオデータファイルを更新 |
| `firewall status` | UFW の状態を表示 |
| `firewall apply` | 設定済みの UFW ルールを再適用 |
| `tune` | 任意のネットワークチューニングを適用 |
| `reality scan` | REALITY ターゲットをプロブ |
| `vless-encryption on\|off\|status` | VLESS ペイロード暗号化の管理 |
| `tor on\|off` | エグジットノードの Tor ルーティング (任意) |
| `reinstall [--commit COMMIT]` | レビュー済みコミットをクリーンに再インストールし、状態を保持 |

## VLESS 暗号化

新規エッジインストールでは Xray-core の VLESS 暗号化を有効にするにゃ。
公式の `xray vlessenc` コマンドが X25519 認証済みペアを 1 組生成し、一時的な鍵交換は
ポスト量子耐性を保つにゃ。サーバーとクライアントの文字列は `secrets.json`
に保持されるにゃ。

既存ノードは現在のクライアントを維持するため、暗号化を無効のままアップグレードするにゃ:

```bash
sudo kokoro-xray vless-encryption on
kokoro-xray link
```

有効化・無効化はすべてのクライアントプロファイルを変更するにゃ。その後にリンクを再取得してねにゃ。
VLESS レイヤーは XHTTP 内部のペイロードを保護するにゃ。トランスポートのセキュリティと
検閲回避には引き続き TLS または REALITY が必要だにゃ。

## REALITY ターゲットスキャン

```bash
kokoro-xray reality scan
kokoro-xray reality scan --domains www.sky.com,github.com
kokoro-xray reality scan --apply
sudo kokoro-xray apply
```

スキャナは DNS、TLS 1.3、ALPN `h2`、証明書カバレッジ、リダイレクト動作を確認するにゃ。

## ファイル

- インストールディレクトリ: `/opt/kokoro-xray`
- コマンドシンボリックリンク: `/usr/local/bin/kokoro-xray`
- 設定: `~/.kokoro-xray/config.json`
- シークレット: `~/.kokoro-xray/secrets.json`
- Xray 設定: `/usr/local/etc/xray/config.json`
- Caddyfile: `/etc/caddy/Caddyfile`

## 備考

- Xray のダウンロードはアップストリームの SHA256 ダイジェストファイルで検証されるにゃ。
- Xray-core は最新かつテスト済みの安定リリースにピン留めされているにゃ。
- Caddy ビルドはピン留めされており、必要な場合のみ再ビルドされるにゃ。
- ディストリビューションの Go が古い場合、Caddy ビルドは `/usr/local/kokoro-go` 以下の管理済み Go ツールチェーンを使うにゃ。
- ファイアウォール対応を有効にすると、UFW は受信デニ・送信アローがデフォルトになるにゃ。
- XMUX はスループットのために `maxConcurrency: "5-10"` を使うにゃ。Xray-core v26.6.27 以降はデフォルトが `maxConnections: 6` (anti-RKN) に変更されたが、これは HTTP/2 の接続プールを制限し、大容量ダウンロードのボトルネックになるにゃ。`maxConcurrency: "5-10"` は接続内での多重化を許可しつつ、フィンガープリンティングを避けるため値をランダム化するにゃ。

## ライセンス

MIT
