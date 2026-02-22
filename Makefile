# ─── OpenClaw 安装 Makefile ──────────────────────────────────────────
#
# 适用于低资源机器 (2 核 / 4GB 内存)。
#
# openclaw-gateway 已作为 root 用户级 systemd 服务运行
# (openclaw-gateway.service)。deploy 目标会平滑更新全局包
# 并重启服务，尽量减少停机时间。
#
# 用法:
#   make deps        – 安装 pnpm 依赖 (低并发)
#   make build       – 编译 TypeScript → dist/
#   make pack        – 创建可安装的 tarball
#   make deploy      – 编译 + 全局安装 + 重启 gateway
#   make deploy-only – 部署已有 tarball (跳过编译)
#   make restart     – 仅重启 gateway，不重新安装
#   make status      – 查看 gateway 服务状态
#   make logs        – 实时查看 gateway 日志
#   make clean       – 清理 dist/ 和 tarball
#   make all         – 完整流程: deps → build → deploy
# ─────────────────────────────────────────────────────────────────────

SHELL := /bin/bash

# ── 可调参数 (命令行覆盖: make build NODE_MEM=768) ──────────────────
NODE_MEM       ?= 512
NETWORK_CONC   ?= 4
CHILD_CONC     ?= 1
# ────────────────────────────────────────────────────────────────────

# 使用 Makefile 所在目录，而非 pwd，以支持 make -C 调用。
PROJECT_DIR    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SERVICE_NAME   := openclaw-gateway.service
SERVICE_FILE   := /root/.config/systemd/user/$(SERVICE_NAME)
GLOBAL_PKG_DIR := /usr/lib/node_modules/openclaw
PACK_DIR       := $(PROJECT_DIR)/.pack

# 延迟求值: 只在实际引用时才执行 node，make help/clean 不依赖 node。
VERSION = $(shell node -e "console.log(require('$(PROJECT_DIR)/package.json').version)")

# systemctl 操作 root 用户级服务的前缀
# 使用 sudo -u root 是因为 Makefile 可能由非 root 用户 (如 maxwell) 执行，
# 但服务运行在 root 的用户级 systemd 实例中。
SYSTEMCTL_ROOT := sudo -u root XDG_RUNTIME_DIR=/run/user/0 systemctl --user

.PHONY: all deps build pack deploy deploy-only _do-deploy install-global restart stop status logs clean preflight help

# ── 默认目标 ─────────────────────────────────────────────────────────
all: deps build deploy

# ── 预检 ─────────────────────────────────────────────────────────────
preflight:
	@echo "── 预检 ──"
	@command -v node  >/dev/null || { echo "错误: 未找到 node";  exit 1; }
	@command -v pnpm  >/dev/null || { echo "错误: 未找到 pnpm";  exit 1; }
	@echo "node  $$(node -v)"
	@echo "pnpm  $$(pnpm -v)"
	@echo "可用内存: $$(awk '/MemAvailable/{printf "%.0fMB", $$2/1024}' /proc/meminfo)"
	@echo "磁盘剩余: $$(df -h --output=avail / | tail -1 | xargs)"
	@echo "源码版本: $(VERSION)"
	@MEM_MB=$$(awk '/MemAvailable/{printf "%.0f", $$2/1024}' /proc/meminfo); \
		if [ "$$MEM_MB" -lt 1536 ]; then \
			echo "警告: 可用内存 $${MEM_MB}MB < 1536MB，构建可能 OOM (建议关闭其他进程或增加 swap)"; \
		fi
	@echo "── 通过 ──"

# ── 安装依赖 ─────────────────────────────────────────────────────────
deps: preflight
	@echo "── 安装依赖 (network-concurrency=$(NETWORK_CONC), child-concurrency=$(CHILD_CONC)) ──"
	cd "$(PROJECT_DIR)" && pnpm install --frozen-lockfile \
		--network-concurrency $(NETWORK_CONC) \
		--child-concurrency $(CHILD_CONC)
	@echo "── 依赖安装完成 ──"

# ── 构建 ─────────────────────────────────────────────────────────────
# NODE_OPTIONS 仅在此目标中局部设置，不污染其他步骤。
build: preflight
	@test -d "$(PROJECT_DIR)/node_modules" || { echo "错误: node_modules 不存在，请先 make deps"; exit 1; }
	@echo "── 构建中 (max-old-space-size=$(NODE_MEM)MB) ──"
	cd "$(PROJECT_DIR)" && NODE_OPTIONS="--max-old-space-size=$(NODE_MEM)" pnpm build
	@test -f "$(PROJECT_DIR)/dist/index.js" || { echo "错误: dist/index.js 未生成"; exit 1; }
	@echo "── 构建完成 (dist/index.js ok) ──"

# ── 打包 tarball ─────────────────────────────────────────────────────
# 使用 --pack-destination 输出到固定目录，避免文件名猜测。
pack: build
	@rm -rf "$(PACK_DIR)"
	@mkdir -p "$(PACK_DIR)"
	@echo "── 打包中 ──"
	cd "$(PROJECT_DIR)" && pnpm pack --pack-destination "$(PACK_DIR)"
	@TARBALL_FILE=$$(ls "$(PACK_DIR)"/*.tgz 2>/dev/null | head -1); \
		test -n "$$TARBALL_FILE" || { echo "错误: tarball 未创建"; exit 1; }; \
		echo "── 打包完成 ($$(du -h "$$TARBALL_FILE" | cut -f1)) ──"

# ── 部署: 编译 + 全局安装 + 重启服务 ────────────────────────────────
deploy: pack
	@$(MAKE) --no-print-directory _do-deploy

# ── 快速部署: 使用已有 tarball (跳过编译) ────────────────────────────
deploy-only:
	@TARBALL_FILE=$$(ls "$(PACK_DIR)"/*.tgz 2>/dev/null | head -1); \
		test -n "$$TARBALL_FILE" || { echo "错误: $(PACK_DIR) 中无 tarball，请先 make pack"; exit 1; }
	@$(MAKE) --no-print-directory _do-deploy

# 实际部署逻辑 (内部目标)
# 顺序: 先安装新版本 → 再停旧服务 → 更新配置 → 启动，减少停机窗口。
_do-deploy:
	@TARBALL_FILE=$$(ls "$(PACK_DIR)"/*.tgz 2>/dev/null | head -1); \
	test -n "$$TARBALL_FILE" || { echo "错误: $(PACK_DIR) 中无 tarball"; exit 1; }; \
	echo "── 部署 v$(VERSION) ──"; \
	echo "  1/4  全局安装新版本 …"; \
	sudo npm install -g --ignore-scripts "$$TARBALL_FILE"
	@echo "  2/4  停止 gateway …"
	$(SYSTEMCTL_ROOT) stop $(SERVICE_NAME) 2>/dev/null || true
	@echo "  3/4  更新服务配置 …"
	@# 检查服务文件中是否有需要更新的字段
	@grep -q 'OPENCLAW_SERVICE_VERSION=' "$(SERVICE_FILE)" \
		|| echo "警告: 服务文件中未找到 OPENCLAW_SERVICE_VERSION"
	sudo sed -i \
		-e "s|^Description=.*|Description=OpenClaw Gateway (v$(VERSION))|" \
		-e "s|OPENCLAW_SERVICE_VERSION=.*|OPENCLAW_SERVICE_VERSION=$(VERSION)|" \
		"$(SERVICE_FILE)"
	$(SYSTEMCTL_ROOT) daemon-reload
	@echo "  4/4  启动 gateway …"
	$(SYSTEMCTL_ROOT) start $(SERVICE_NAME) || \
		{ echo "错误: gateway 启动失败，最近日志:"; \
		  sudo -u root XDG_RUNTIME_DIR=/run/user/0 journalctl --user-unit $(SERVICE_NAME) -n 20 --no-pager; \
		  exit 1; }
	@# 轮询等待服务稳定运行 (最多 10 秒)
	@echo -n "  等待服务稳定 "; \
	for i in 1 2 3 4 5 6 7 8 9 10; do \
		sleep 1; \
		echo -n "."; \
		if ! $(SYSTEMCTL_ROOT) is-active --quiet $(SERVICE_NAME) 2>/dev/null; then \
			echo ""; \
			echo "错误: gateway 在启动后崩溃，最近日志:"; \
			sudo -u root XDG_RUNTIME_DIR=/run/user/0 journalctl --user-unit $(SERVICE_NAME) -n 20 --no-pager; \
			exit 1; \
		fi; \
	done; echo " ok"
	@$(MAKE) --no-print-directory status
	@echo "── 部署完成 ──"

# ── 仅全局安装 (不重启) ─────────────────────────────────────────────
install-global: pack
	@TARBALL_FILE=$$(ls "$(PACK_DIR)"/*.tgz 2>/dev/null | head -1); \
	test -n "$$TARBALL_FILE" || { echo "错误: $(PACK_DIR) 中无 tarball"; exit 1; }; \
	sudo npm install -g --ignore-scripts "$$TARBALL_FILE"
	@echo "── 已全局安装 v$(VERSION) ──"

# ── 服务管理 ─────────────────────────────────────────────────────────
restart:
	@echo "── 重启 gateway ──"
	$(SYSTEMCTL_ROOT) restart $(SERVICE_NAME)
	@sleep 2
	@$(MAKE) --no-print-directory status

stop:
	$(SYSTEMCTL_ROOT) stop $(SERVICE_NAME)
	@echo "── gateway 已停止 ──"

status:
	@$(SYSTEMCTL_ROOT) status $(SERVICE_NAME) --no-pager || true
	@echo ""
	@echo "全局版本: $$(node -e "try{console.log(require('$(GLOBAL_PKG_DIR)/package.json').version)}catch{console.log('未安装')}")"
	@echo "源码版本: $(VERSION)"

logs:
	sudo -u root XDG_RUNTIME_DIR=/run/user/0 journalctl --user-unit $(SERVICE_NAME) -f --no-pager

# ── 清理 ─────────────────────────────────────────────────────────────
clean:
	rm -rf "$(PROJECT_DIR)/dist/"
	rm -rf "$(PACK_DIR)"
	@echo "── 已清理 ──"

# ── 帮助 ─────────────────────────────────────────────────────────────
help:
	@echo "OpenClaw Makefile (低资源模式)"
	@echo ""
	@echo "  make deps        安装 pnpm 依赖"
	@echo "  make build       编译 TypeScript"
	@echo "  make pack        创建可安装的 tarball"
	@echo "  make deploy      完整部署: pack → install → stop → start"
	@echo "  make deploy-only 部署已有 tarball (跳过编译)"
	@echo "  make restart     重启 gateway 服务"
	@echo "  make stop        停止 gateway 服务"
	@echo "  make status      查看 gateway 状态和版本"
	@echo "  make logs        实时查看 gateway 日志"
	@echo "  make clean       清理 dist/ 和 tarball"
	@echo "  make all         deps → build → deploy"
	@echo ""
	@echo "可调参数 (命令行覆盖):"
	@echo "  NODE_MEM=512       Node.js 最大堆内存 MB (默认: 512)"
	@echo "  NETWORK_CONC=4     pnpm 网络并发数      (默认: 4)"
	@echo "  CHILD_CONC=1       pnpm 子进程并发数    (默认: 1)"
