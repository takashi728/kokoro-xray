# kokoro-xray

<p align="center">
  <img src="docs/img/kokoro-neko.jpg" alt="kokoro-xray" width="360">
</p>

Xray のエッジ/エグジット構築用の小さなシェルマネージャーだにゃ〜

スクリプトは状態を JSON で保持し、`jq` で設定をレンダリングし、リロード前に検証を行い、大きなフレームワークへの依存をさけているにゃ。

[English](README.md) | [日本語](README.ja.md)

## サポートモード

- エッジ単一ノード: VLESS XHTTP REALITY、TLS、または両方
- エッジ + エグジット: エッジが WireGuard を経てトラフィックをエグジットに転送
- TLS エッジ: Caddy が ACME と HTTPS ルーティングを処理
- REALITY エッジ: Xray がパブリックの `:443` を直接提供

## 要件

- Debian または Ubuntu
- ルート権限
- エッジノードで `443/tcp` を開放
- TLS エッジノードでは ACME のため `80/tcp` を開放
- エッジ + エグジットを使う場合はエグジットノードの UDP ポートを開放 (デフォルト `51820/udp`)

## インストール

```bash
curl -fsSL https://raw.githubusercontent.com/takashi728/kokoro-xray/codebase-redesign-with-func/install.sh | sudo bash
```

エッジをセットアップにゃ:

```bash
sudo kokoro-xray edge
```

エグジットをセットアップにゃ:

```bash
sudo kokoro-xray exit
```

## 更新

ふつうの更新では既存の状態を保持するにゃ:

```bash
curl -fsSL https://raw.githubusercontent.com/takashi728/kokoro-xray/codebase-redesign-with-func/install.sh | sudo bash
sudo kokoro-xray apply
```

クリーンな再インストールは `/opt/kokoro-xray` を削除し、`~/.kokoro-xray` は保持するにゃ:

```bash
sudo kokoro-xray reinstall
sudo kokoro-xray apply
```

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
| `reinstall [--branch BRANCH]` | コードをクリーンに再インストールし、状態と現在のブランチを保持 |

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
