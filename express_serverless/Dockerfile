FROM public.ecr.aws/lambda/nodejs:22-arm64

# 作業ディレクトリを明示
WORKDIR /var/task

# パッケージ情報のみをまずコピー（キャッシュ効率向上）
COPY package.json package-lock.json ./

# 依存関係のインストール
RUN npm install

# アプリケーションコードのコピー（srcフォルダ）
COPY *.js ./

# Lambdaハンドラを指定
CMD ["lambda.handler"]
