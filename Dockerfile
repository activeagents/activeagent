FROM ruby:3.3-slim

# Install system dependencies
RUN apt-get update -qq && apt-get install -y \
  build-essential \
  git \
  curl \
  wget \
  unzip \
  libssl-dev \
  libreadline-dev \
  zlib1g-dev \
  libsqlite3-dev \
  pkg-config \
  # For ONNX Runtime
  libgomp1 \
  # For PyTorch/LibTorch (torch-rb)
  libtorch-dev \
  libopenblas-dev \
  # For transformers and NLP
  python3 \
  python3-pip \
  # Clean up
  && rm -rf /var/lib/apt/lists/*

# Install Python dependencies for model conversion tools (optional)
RUN pip3 install --no-cache-dir \
  onnx \
  onnxconverter-common \
  transformers

# Set up working directory
WORKDIR /activeagent

# Copy gemfiles first for better caching
COPY Gemfile* activeagent.gemspec ./
COPY lib/active_agent/version.rb ./lib/active_agent/

# Install Ruby dependencies
RUN bundle config set --local deployment 'false' && \
    bundle config set --local without 'production' && \
    bundle install --jobs 4 --retry 3

# Copy the rest of the application
COPY . .

# Create models directory
RUN mkdir -p models

# Set environment variables for optimal performance
ENV OMP_NUM_THREADS=4
ENV MKL_NUM_THREADS=4
ENV RAILS_ENV=development

# Default command
CMD ["bin/rails", "server", "-b", "0.0.0.0"]