# 🚀 START HERE - LlamaStack RHACM Deployment

## The Simplest Path (5 Minutes to Start)

```bash
# 1. Go to the deployment directory
cd ~/Documents/claude_projects/llama-install/rhacm-deployment

# 2. Make sure you're on your RHACM hub cluster
oc config use-context <hub-cluster-name>

# 3. Run the automated deployment script
./deploy.sh
```

That's it! The script will:
- Ask you for your cluster name and tokens
- Deploy everything automatically
- Take ~40-50 minutes total

---

## What You Need Ready

Before running `./deploy.sh`, have these ready:

- [ ] RHACM hub cluster access (logged in with `oc`)
- [ ] Name of your GPU-enabled managed cluster
- [ ] Hugging Face Llama token: `hf_xxxxxxxxxxxxx`
- [ ] Hugging Face Granite token: `hf_xxxxxxxxxxxxx`

**Optional:**
- [ ] Slack bot token (or just press Enter to skip)
- [ ] Slack team ID (or just press Enter to skip)

---

## During Deployment

### Open a second terminal to monitor:

```bash
# Terminal 2 - Monitor progress
watch ./get-status.sh <your-cluster-name>
```

### Timeline to expect:

```
00:00 - Script starts, labels cluster
00:02 - Deploys policies
00:05 - Operators start installing ☕ (wait 15-20 min)
00:25 - GPU drivers start installing (wait 10-15 min)
00:40 - Granite model starts loading (wait 5-10 min)
00:50 - ✅ Everything is ready!
```

---

## After Deployment

### Get your access URLs:

```bash
./get-urls.sh <your-cluster-name>
```

### Open Streamlit in your browser:

The script output will give you the URL, something like:
```
https://streamlit-llama-serve.apps.rosa-xxxxx.xxxx.openshiftapps.com
```

---

## Need More Control?

If you want to understand each step or do manual deployment:

1. **Quick Reference**: Read `QUICK-START.md`
2. **Full Guide**: Read `README.md`
3. **File Explanations**: Read `FILES-GUIDE.md`

---

## Troubleshooting

### Script won't run?
```bash
# Make sure it's executable
chmod +x deploy.sh
```

### Not sure which cluster to use?
```bash
# List all managed clusters
oc get managedclusters
```

### Need to check token format?
```
Llama token should start with:  hf_
Granite token should start with: hf_
```

### Deployment seems stuck?
```bash
# Check what's happening
./get-status.sh <cluster-name>

# Check policies
oc get policy -n llama-stack-policies
```

---

## Multi-Cluster Deployment

Want to deploy to multiple GPU clusters?

Just run the script again for each cluster:

```bash
# Cluster 1
GPU_CLUSTER=cluster-1 ./deploy.sh

# Cluster 2  
GPU_CLUSTER=cluster-2 ./deploy.sh

# Cluster 3
GPU_CLUSTER=cluster-3 ./deploy.sh
```

Or label multiple clusters and they'll get deployed automatically via the ApplicationSet!

---

## Quick Decision Tree

```
┌─────────────────────────────────────┐
│ Do you have 5 minutes right now?   │
└──────────────┬──────────────────────┘
               │
        ┌──────┴──────┐
        │             │
       YES           NO
        │             │
        │             └──> Read README.md first, come back later
        │
        └──> Run ./deploy.sh NOW!
             │
             └──> Monitor with ./get-status.sh
                  │
                  └──> Get URLs with ./get-urls.sh (after 50 min)
```

---

## Support

- **Status check**: `./get-status.sh <cluster>`
- **Get URLs**: `./get-urls.sh <cluster>`
- **Full docs**: `less README.md`
- **Quick ref**: `cat QUICK-START.md`

---

**Ready? Let's go!**

```bash
./deploy.sh
```
