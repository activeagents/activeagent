# frozen_string_literal: true

module ActionAgent
  # SandboxInstanceTier
  #
  # Defines available instance sizes for sandbox sessions.
  # Similar to Google Colab or Hugging Face Spaces hardware tiers.
  #
  # Usage:
  #   tier = SandboxInstanceTier.find(:gpu_t4)
  #   tier.cpu_cores      # => 4
  #   tier.memory_gb      # => 16
  #   tier.gpu            # => "nvidia-t4"
  #   tier.hourly_cost    # => 0.35
  #
  class SandboxInstanceTier
    include ActiveModel::Model
    include ActiveModel::Attributes

    attribute :id, :string
    attribute :name, :string
    attribute :description, :string
    attribute :cpu_cores, :integer
    attribute :memory_gb, :integer
    attribute :disk_gb, :integer
    attribute :gpu, :string
    attribute :gpu_memory_gb, :integer
    attribute :hourly_cost, :decimal
    attribute :monthly_cost, :decimal
    attribute :available, :boolean, default: true
    attribute :category, :string  # free, pro, enterprise

    # Instance tier definitions
    # Pricing modeled after Colab/HuggingFace/Lambda Labs
    TIERS = {
      # --- Free Tier ---
      free: {
        id: "free",
        name: "Free",
        description: "Basic CPU instance for testing",
        cpu_cores: 2,
        memory_gb: 4,
        disk_gb: 10,
        gpu: nil,
        gpu_memory_gb: nil,
        hourly_cost: 0.00,
        monthly_cost: 0.00,
        category: "free"
      },

      # --- CPU Tiers ---
      cpu_small: {
        id: "cpu_small",
        name: "CPU Small",
        description: "2 vCPUs, 8GB RAM",
        cpu_cores: 2,
        memory_gb: 8,
        disk_gb: 20,
        gpu: nil,
        gpu_memory_gb: nil,
        hourly_cost: 0.05,
        monthly_cost: 36.00,
        category: "pro"
      },

      cpu_medium: {
        id: "cpu_medium",
        name: "CPU Medium",
        description: "4 vCPUs, 16GB RAM",
        cpu_cores: 4,
        memory_gb: 16,
        disk_gb: 50,
        gpu: nil,
        gpu_memory_gb: nil,
        hourly_cost: 0.10,
        monthly_cost: 72.00,
        category: "pro"
      },

      cpu_large: {
        id: "cpu_large",
        name: "CPU Large",
        description: "8 vCPUs, 32GB RAM",
        cpu_cores: 8,
        memory_gb: 32,
        disk_gb: 100,
        gpu: nil,
        gpu_memory_gb: nil,
        hourly_cost: 0.20,
        monthly_cost: 144.00,
        category: "pro"
      },

      cpu_xlarge: {
        id: "cpu_xlarge",
        name: "CPU XLarge",
        description: "16 vCPUs, 64GB RAM",
        cpu_cores: 16,
        memory_gb: 64,
        disk_gb: 200,
        gpu: nil,
        gpu_memory_gb: nil,
        hourly_cost: 0.40,
        monthly_cost: 288.00,
        category: "enterprise"
      },

      # --- GPU Tiers ---
      gpu_t4: {
        id: "gpu_t4",
        name: "GPU T4",
        description: "NVIDIA T4 (16GB VRAM), 4 vCPUs, 16GB RAM",
        cpu_cores: 4,
        memory_gb: 16,
        disk_gb: 50,
        gpu: "nvidia-tesla-t4",
        gpu_memory_gb: 16,
        hourly_cost: 0.35,
        monthly_cost: 252.00,
        category: "pro"
      },

      gpu_l4: {
        id: "gpu_l4",
        name: "GPU L4",
        description: "NVIDIA L4 (24GB VRAM), 8 vCPUs, 32GB RAM",
        cpu_cores: 8,
        memory_gb: 32,
        disk_gb: 100,
        gpu: "nvidia-l4",
        gpu_memory_gb: 24,
        hourly_cost: 0.70,
        monthly_cost: 504.00,
        category: "pro"
      },

      gpu_a10g: {
        id: "gpu_a10g",
        name: "GPU A10G",
        description: "NVIDIA A10G (24GB VRAM), 8 vCPUs, 32GB RAM",
        cpu_cores: 8,
        memory_gb: 32,
        disk_gb: 100,
        gpu: "nvidia-a10g",
        gpu_memory_gb: 24,
        hourly_cost: 1.00,
        monthly_cost: 720.00,
        category: "enterprise"
      },

      gpu_a100_40: {
        id: "gpu_a100_40",
        name: "GPU A100 40GB",
        description: "NVIDIA A100 (40GB VRAM), 12 vCPUs, 85GB RAM",
        cpu_cores: 12,
        memory_gb: 85,
        disk_gb: 200,
        gpu: "nvidia-a100-40gb",
        gpu_memory_gb: 40,
        hourly_cost: 2.50,
        monthly_cost: 1800.00,
        category: "enterprise"
      },

      gpu_a100_80: {
        id: "gpu_a100_80",
        name: "GPU A100 80GB",
        description: "NVIDIA A100 (80GB VRAM), 12 vCPUs, 170GB RAM",
        cpu_cores: 12,
        memory_gb: 170,
        disk_gb: 200,
        gpu: "nvidia-a100-80gb",
        gpu_memory_gb: 80,
        hourly_cost: 4.00,
        monthly_cost: 2880.00,
        category: "enterprise"
      },

      # --- High Memory Tiers ---
      highmem_medium: {
        id: "highmem_medium",
        name: "High Memory Medium",
        description: "4 vCPUs, 64GB RAM",
        cpu_cores: 4,
        memory_gb: 64,
        disk_gb: 100,
        gpu: nil,
        gpu_memory_gb: nil,
        hourly_cost: 0.25,
        monthly_cost: 180.00,
        category: "pro"
      },

      highmem_large: {
        id: "highmem_large",
        name: "High Memory Large",
        description: "8 vCPUs, 128GB RAM",
        cpu_cores: 8,
        memory_gb: 128,
        disk_gb: 200,
        gpu: nil,
        gpu_memory_gb: nil,
        hourly_cost: 0.50,
        monthly_cost: 360.00,
        category: "enterprise"
      }
    }.freeze

    class << self
      def all
        TIERS.values.map { |attrs| new(attrs) }
      end

      def find(id)
        id = id.to_sym
        raise ArgumentError, "Unknown tier: #{id}" unless TIERS.key?(id)

        new(TIERS[id])
      end

      def available
        all.select(&:available)
      end

      def by_category(category)
        all.select { |t| t.category == category.to_s }
      end

      def cpu_tiers
        all.select { |t| t.gpu.nil? }
      end

      def gpu_tiers
        all.select { |t| t.gpu.present? }
      end

      def free_tier
        find(:free)
      end

      def default_tier
        find(:cpu_small)
      end
    end

    def free?
      hourly_cost.zero?
    end

    def has_gpu?
      gpu.present?
    end

    def display_price
      if free?
        "Free"
      else
        "$#{format('%.2f', hourly_cost)}/hr"
      end
    end

    def display_specs
      specs = [ "#{cpu_cores} vCPU", "#{memory_gb}GB RAM", "#{disk_gb}GB disk" ]
      specs << "#{gpu_memory_gb}GB #{gpu_display_name}" if has_gpu?
      specs.join(" | ")
    end

    def gpu_display_name
      return nil unless gpu

      case gpu
      when "nvidia-tesla-t4" then "T4"
      when "nvidia-l4" then "L4"
      when "nvidia-a10g" then "A10G"
      when "nvidia-a100-40gb" then "A100 40GB"
      when "nvidia-a100-80gb" then "A100 80GB"
      else gpu.gsub("nvidia-", "").upcase
      end
    end

    # Convert to Incus resource limits
    def to_incus_limits
      limits = {
        "limits.cpu" => cpu_cores.to_s,
        "limits.memory" => "#{memory_gb}GB",
        "limits.processes" => (cpu_cores * 250).to_s
      }

      # GPU passthrough requires host configuration
      if has_gpu?
        limits["nvidia.runtime"] = "true"
        limits["nvidia.require.cuda"] = "true"
      end

      limits
    end

    # Convert to Kubernetes resource spec
    def to_kubernetes_resources
      resources = {
        requests: {
          cpu: "#{cpu_cores * 500}m",
          memory: "#{memory_gb / 2}Gi"
        },
        limits: {
          cpu: cpu_cores.to_s,
          memory: "#{memory_gb}Gi"
        }
      }

      if has_gpu?
        resources[:limits]["nvidia.com/gpu"] = "1"
      end

      resources
    end

    # GCP machine type mapping
    def gcp_machine_type
      if has_gpu?
        # GPU instances use n1 or a2 series
        case gpu
        when "nvidia-a100-40gb", "nvidia-a100-80gb"
          "a2-highgpu-1g"
        else
          "n1-standard-#{cpu_cores}"
        end
      elsif memory_gb > cpu_cores * 8
        # High memory ratio
        "n2-highmem-#{cpu_cores}"
      else
        "n2-standard-#{cpu_cores}"
      end
    end

    # GCP accelerator config
    def gcp_accelerator_config
      return nil unless has_gpu?

      {
        accelerator_type: gpu,
        accelerator_count: 1
      }
    end

    def as_json(*)
      {
        id: id,
        name: name,
        description: description,
        specs: {
          cpu_cores: cpu_cores,
          memory_gb: memory_gb,
          disk_gb: disk_gb,
          gpu: gpu,
          gpu_memory_gb: gpu_memory_gb
        },
        pricing: {
          hourly_cost: hourly_cost.to_f,
          monthly_cost: monthly_cost.to_f,
          display: display_price
        },
        category: category,
        available: available
      }
    end
  end
end
