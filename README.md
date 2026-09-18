# totvs-webagent-proxy

Proxy nativo para macOS que permite ao TOTVS Protheus WebApp usar o WebAgent local versão 1.1.1 ou superior em navegadores que exigem WSS, incluindo Safari.

Mantenha a porta configurada no Protheus/WebAgent em `21021`. O proxy aceita WS puro do Chrome e WSS do Safari nessa porta e inicia uma instância interna do WebAgent em `127.0.0.1:21022`.

## Requisitos

- macOS 13 ou superior;
- TOTVS WebAgent 1.1.1 ou superior instalado em `/Applications/web-agent.app`.

A instalação do WebAgent 1.1.1 pode não incluir os certificados necessários. Obtenha os arquivos abaixo e adicione-os nesta pasta da instalação local:

```text
/Applications/web-agent.app/Contents/MacOS/
```

Arquivos usados pelo proxy:

```text
totvs_certificate.crt
totvs_certificate_key.pem
```

O proxy lê esses arquivos diretamente do WebAgent. Certificados, chaves privadas e binários TOTVS não fazem parte deste repositório.

## Build

```bash
./scripts/build.sh
```

O build gera `dist/totvs-webagent-proxy` como Universal Binary para Apple Silicon e Intel.

## Execução manual

```bash
./dist/totvs-webagent-proxy start
```

Comandos disponíveis:

```bash
./dist/totvs-webagent-proxy status
./dist/totvs-webagent-proxy log
./dist/totvs-webagent-proxy version
./dist/totvs-webagent-proxy help
```

`log` executa `tail -f ~/Library/Logs/totvs-webagent-proxy.log`.

O WebAgent é iniciado sob demanda com `--tray --port 21022 --locallog 1`. Ele permanece ativo enquanto houver conexões abertas e é encerrado 60 segundos após a última conexão fechar.

## Instalação automática

```bash
./scripts/build.sh
./scripts/install.sh
```

O instalador copia o binário para `/usr/local/bin` e registra o LaunchAgent `com.totvs.webagent-proxy`, que inicia o proxy no login e o mantém aguardando conexões na porta `21021`.

Para remover:

```bash
./scripts/uninstall.sh
```

## Releases automáticas

Todo push na `main` executa o build de validação no GitHub Actions. Para publicar uma versão, envie uma tag semântica iniciada por `v`:

```bash
git tag v0.1.1
git push origin v0.1.1
```

O GitHub Actions gera o Universal Binary, cria a Release e anexa `totvs-webagent-proxy`. A versão apresentada por `totvs-webagent-proxy version` no binário publicado será `0.1.1`.

## Validação realizada

- Safari com WSS;
- Chrome com WS puro;
- sessão ociosa com conexão aberta;
- shutdown do WebAgent após 60 segundos sem conexões;
- reinício do WebAgent sob demanda.

## Aviso

Projeto independente e não oficial. TOTVS, Protheus e WebAgent são marcas e produtos de seus respectivos titulares. Este projeto não possui afiliação ou endosso da TOTVS.
