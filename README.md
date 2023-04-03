# proxyer

> 本工具仅供学术、研究和合法用途；使用时请遵守所在国家/地区的法律法规。

在工作和生活的无数场景都需要用到代理服务器进行科学上网，当拿到一台初始化状态的 vps 时，或多或少需要花费些时间进行软件的配置和更新，本工具的目的就是为了让你可以一键完成配置。

目前仅支持 Debian 系统，要求使用 root 账户执行。

![image](https://user-images.githubusercontent.com/2698003/229393195-3b1133b3-122b-4f77-a666-4a86a040831a.png)


### 使用说明

如果你要使用 wss 和 http2 代理，过程中会要求填入域名，方便自动完成证书的部署。

```bash
# wget install 
wget --no-check-certificate https://raw.githubusercontent.com/barretlee/proxyer/master/install.sh && chmod +x install.sh && sudo ./install.sh

# curl install
curl -O https://raw.githubusercontent.com/barretlee/proxyer/master/install.sh && chmod +x install.sh && sudo ./install.sh
```


### 执行过程

整个程序的执行过程：

- 安装必要的依赖，例如 dig/nslookup/wget/curl 等
- 选择代理类型：Websocket/Shadowsocks/HTTP2
  - 针对不同的类型，输入必要的参数，如加密方式、账密、域名、端口等
- 自动完成 Docker、代理程序、证书的安装和配置
- 自动启动代理程序

涉及到的参数包括，可以现在环境变量全部设置好，避免在程序执行过程中交互：

```bash
# 配置证书时需要
export cert_domain="your_domain.com"
export cert_email="your@email.com"

export user="user_name"
# 为了方便，几种代理都是用同一个密码
export pass="password"

# shadowsocks 会使用
export encrypt_type="aes-256-cfb"

# 端口设置
export port_shadowsocks=8433
export port_wss=4433
export port_http2=443
```

### License

[MIT](./LICENSE)
