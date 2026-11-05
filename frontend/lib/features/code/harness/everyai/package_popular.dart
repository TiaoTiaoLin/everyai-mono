// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

/// Widely used package names per registry, separated by spaces: the names a typosquat imitates (see
/// `typoTargetOf` in `package_check.dart`), and names the package check never looks up.
///
/// Hand-written from the registries' most-downloaded lists as of 2026 (npm weekly downloads, PyPI's top
/// projects, crates.io, rubygems.org and pub.dev "most popular"); names only, in rough order of use. They go stale
/// slowly, and a stale list only misses look-alikes of a newly popular package. PyPI names are in PEP 503 form.
library;

const popularNpm =
    'react react-dom lodash express axios typescript chalk commander debug tslib semver uuid moment dotenv '
    'webpack eslint prettier jest mocha chai vue next nuxt svelte vite esbuild rollup babel-core @babel/core '
    '@babel/preset-env @babel/runtime @types/node @types/react @types/react-dom @types/jest @types/express '
    '@types/lodash yargs minimist glob rimraf mkdirp fs-extra cross-env nodemon concurrently body-parser '
    'cors cookie-parser morgan helmet jsonwebtoken bcrypt bcryptjs mongoose mongodb mysql mysql2 pg redis '
    'ioredis sequelize prisma @prisma/client knex sqlite3 better-sqlite3 socket.io socket.io-client ws '
    'node-fetch cross-fetch got request superagent qs classnames clsx styled-components @emotion/react '
    '@emotion/styled tailwindcss postcss autoprefixer sass less react-router react-router-dom redux '
    'react-redux @reduxjs/toolkit zustand mobx rxjs immer zod yup joi ajv date-fns dayjs luxon underscore '
    'ramda bluebird async inquirer ora boxen colors kleur picocolors ansi-styles strip-ansi string-width '
    'supports-color color-name color-convert escape-string-regexp has-flag source-map source-map-support '
    'graceful-fs once inherits readable-stream safe-buffer buffer events process util path-to-regexp mime '
    'mime-types form-data formidable multer sharp jimp puppeteer playwright @playwright/test cheerio jsdom '
    'marked markdown-it highlight.js prismjs handlebars ejs pug mustache nanoid shortid validator crypto-js '
    'jszip archiver tar xml2js js-yaml yaml ini toml csv-parse papaparse chart.js d3 three antd '
    '@mui/material @mui/icons-material bootstrap jquery angular @angular/core @angular/common @angular/cli '
    '@nestjs/core @nestjs/common koa fastify hapi @hapi/hapi next-auth graphql apollo-server @apollo/client '
    'firebase firebase-admin aws-sdk @aws-sdk/client-s3 stripe openai @anthropic-ai/sdk langchain electron '
    'react-native expo vitest ts-node tsx ts-jest @testing-library/react @testing-library/jest-dom cypress '
    'storybook husky lint-staged eslint-plugin-react @typescript-eslint/parser '
    '@typescript-eslint/eslint-plugin eslint-config-prettier pm2 winston pino log4js http-proxy-middleware '
    'web-vitals framer-motion react-query @tanstack/react-query swr preact lit solid-js astro gatsby turbo '
    'nx lerna pnpm yarn npm';

const popularPypi =
    'boto3 botocore urllib3 requests setuptools certifi idna charset-normalizer typing-extensions '
    'python-dateutil packaging s3transfer six aiobotocore numpy pyyaml pip fsspec s3fs cryptography pydantic '
    'pydantic-core cffi attrs pycparser pandas importlib-metadata jmespath zipp protobuf click wheel '
    'platformdirs rsa pyasn1 markupsafe jinja2 pytz tzdata colorama filelock awscli virtualenv pluggy pytest '
    'wrapt pyjwt jsonschema tomli grpcio aiohttp yarl multidict frozenlist aiosignal pyparsing '
    'google-api-core googleapis-common-protos google-auth cachetools requests-oauthlib oauthlib httpx '
    'httpcore h11 anyio sniffio psutil tqdm pyarrow sqlalchemy greenlet scipy pillow docutils soupsieve '
    'beautifulsoup4 lxml decorator werkzeug flask itsdangerous blinker django djangorestframework fastapi '
    'starlette uvicorn gunicorn tabulate rich pygments markdown-it-py mdurl openpyxl et-xmlfile xlrd '
    'matplotlib kiwisolver cycler fonttools contourpy seaborn plotly scikit-learn joblib threadpoolctl '
    'tensorflow keras torch torchvision transformers tokenizers huggingface-hub safetensors datasets regex '
    'nltk spacy openai anthropic tiktoken langchain langchain-core redis pymongo psycopg2 psycopg2-binary '
    'psycopg pymysql mysqlclient celery kombu paramiko bcrypt pynacl pyopenssl websocket-client websockets '
    'python-dotenv toml tomlkit black isort flake8 pylint mypy ruff coverage pytest-cov pytest-mock '
    'pytest-asyncio tox nox poetry pipenv twine build hatchling setuptools-scm cython numba llvmlite sympy '
    'networkx opencv-python imageio scikit-image shapely geopandas xgboost lightgbm statsmodels pyspark '
    'selenium playwright scrapy mock freezegun faker arrow pendulum simplejson ujson orjson msgpack '
    'marshmallow alembic jupyter notebook ipython ipykernel jupyterlab streamlit gradio dash bokeh boto '
    'google-cloud-storage azure-core azure-storage-blob docker kubernetes ansible fabric invoke sentry-sdk '
    'loguru structlog tenacity retrying backoff more-itertools chardet html5lib pyzmq tornado twisted gevent '
    'eventlet pexpect ptyprocess python-multipart email-validator pydantic-settings typer colorlog termcolor '
    'prompt-toolkit wcwidth filetype python-magic pyinstaller';

const popularCrates =
    'serde serde_json serde_derive tokio rand syn quote proc-macro2 libc log clap anyhow thiserror regex '
    'lazy_static once_cell bitflags cfg-if itertools chrono time futures futures-util bytes hyper reqwest '
    'http url base64 hex sha2 md5 uuid tracing tracing-subscriber env_logger memchr smallvec hashbrown '
    'indexmap parking_lot crossbeam crossbeam-channel rayon num-traits num_cpus getrandom byteorder tempfile '
    'walkdir glob toml serde_yaml csv actix-web axum tower tower-http warp rocket diesel sqlx rusqlite redis '
    'tonic prost async-trait dashmap strum derive_more nom semver dirs directories indicatif console '
    'dialoguer colored termcolor crossterm ratatui image flate2 zip tar ring rustls openssl native-tls '
    'tokio-util async-std mio socket2 pin-project bincode wasm-bindgen js-sys web-sys criterion proptest '
    'mockall insta pretty_assertions';

const popularGems =
    'rails rake bundler rack activesupport activerecord actionpack railties nokogiri json i18n tzinfo '
    'concurrent-ruby minitest rspec rspec-core rspec-rails thor faraday httparty rest-client puma unicorn '
    'sinatra devise pg mysql2 sqlite3 redis sidekiq pry byebug rubocop capybara selenium-webdriver '
    'factory_bot faker webmock vcr simplecov aws-sdk aws-sdk-s3 jwt bcrypt dotenv addressable mime-types '
    'builder erubi loofah mail multi_json oj nio4r websocket-driver zeitwerk bootsnap sass sassc jbuilder '
    'kaminari pundit cancancan cocoapods fastlane jekyll listen ffi racc public_suffix diff-lcs colorize '
    'tty-prompt';

const popularPub =
    'http provider shared_preferences path_provider path intl url_launcher collection meta async '
    'flutter_bloc bloc riverpod flutter_riverpod hooks_riverpod get dio equatable freezed freezed_annotation '
    'json_annotation json_serializable build_runner mockito mocktail test flutter_lints lints '
    'cupertino_icons image_picker file_picker cached_network_image flutter_svg google_fonts go_router '
    'auto_route sqflite drift hive hive_flutter isar firebase_core firebase_auth cloud_firestore '
    'firebase_messaging uuid crypto logger rxdart get_it injectable connectivity_plus device_info_plus '
    'package_info_plus share_plus permission_handler geolocator google_maps_flutter webview_flutter '
    'video_player camera flutter_local_notifications flutter_secure_storage fl_chart lottie shimmer '
    'flutter_animate args yaml web_socket_channel stream_transform characters flutter_dotenv '
    'easy_localization very_good_analysis build source_gen analyzer archive image pdf printing xml html '
    'markdown flutter_markdown url_strategy universal_io';
