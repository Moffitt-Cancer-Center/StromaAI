# Executive Summary: StromaAI

> *"Be water, my friend."* — **StromaAI** is a hybrid orchestration platform designed to provide the fluidity of cloud-based AI services within the rigid constraints of a high-performance computing (HPC) environment.

---

## **The Institutional Value Proposition**

Institutional HPC clusters often face a "resource deadlock": **GPU nodes** are essential for massive research calculations, yet modern **AI-assisted development** (like GitHub Copilot or VS Code extensions) requires permanent, always-on API endpoints.

Traditionally, institutions have had to choose between two inefficient extremes:
1.  **Under-utilization:** Locking down expensive GPUs for "always-on" development tools, which stalls primary research.
2.  **Productivity Loss:** Forcing researchers to wait through long Slurm queues every time they want to use an AI coding assistant.

**StromaAI** resolves this tension by serving as an **intelligent elastic buffer**. It provides a permanent, low-cost "Head Node" for connectivity while dynamically "bursting" into the GPU pool only when active requests are detected.

---

## **Key Operational Advantages**

### **1. Extreme Resource Efficiency**
* **Dynamic Scaling:** Automatically submits Slurm jobs to bring GPU workers online within ~60 seconds of a request.
* **Zero-Waste Reclamation:** Automatically returns GPUs to the general research pool once idle thresholds are reached.
* **Lightweight Control:** The primary API server runs on standard virtual machines (Proxmox/Debian) without requiring a dedicated GPU.

### **2. Institutional Security & Compliance**
* **Identity Integration:** Built-in support for **OIDC (OpenID Connect)** and **Keycloak**, allowing institutions to use existing login credentials and role-based access.
* **Zero-Trust Gateway:** A FastAPI-based gateway ensures that internal API keys are never exposed to end-users, and all traffic is secured via **Nginx TLS encryption**.

### **3. Hardware-Aware Management**
* **Smart Model Selection:** The included `hfw` utility allows administrators to "test-fit" Hugging Face models against local VRAM before downloading, preventing failed deployments.
* **Containerized Portability:** Uses **Apptainer (Singularity)** to ensure the AI environment is reproducible, portable, and compatible with RHEL-family Slurm workers.

---

## **System Architecture Overview**

| Component | Responsibility | Requirement |
| :--- | :--- | :--- |
| **Head Node** | API Gateway, Watcher Daemon, Ray GCS | Proxmox VM (No GPU) |
| **Worker Nodes** | Model Inference, Ray Workers | Slurm GPU Nodes |
| **Storage** | Model Repository, Configuration | Shared NFS/Lustre/GPFS |
| **Interface** | VS Code (OOD) & OpenWebUI | Standard Web Browser |

---

## **Implementation Roadmap**

StromaAI is designed for **rapid institutional adoption**:
* **Automated Deployment:** A single installer handles system users, virtual environments, and service units.
* **Zero-Configuration for Researchers:** Integration with **Open OnDemand (OOD)** means researchers find their AI tools pre-configured and ready to use the moment they log in.
* **Enterprise Monitoring:** Includes pre-built **Prometheus** scrape configs and **Grafana** dashboard generators for real-time visibility into GPU health and request queues.