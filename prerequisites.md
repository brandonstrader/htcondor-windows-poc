# Prerequisites — HTCondor PoC on AWS

Complete these steps on your local machine before running Terraform.

---

## 1. AWS Account

You need an AWS account with billing enabled. All resources are in `us-east-1`.

---

## 2. Create an IAM User for Terraform

Terraform needs programmatic access to create and destroy resources.

### 2a. Sign in to the AWS Console as root or an existing admin

Go to **IAM → Users → Create user**.

- **User name:** `terraform-htcondor-poc`
- **Access type:** Programmatic access only (no console access needed)

### 2b. Attach a permission policy

For a one-time PoC the simplest option is the AWS-managed `AdministratorAccess` policy.
If your security posture requires a narrower policy, attach the custom policy below instead.

<details>
<summary>Narrower custom IAM policy (paste into the JSON editor)</summary>

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:*",
        "vpc:*",
        "elasticfilesystem:*",
        "fsx:*",
        "s3:*",
        "ssm:*",
        "iam:CreateRole", "iam:DeleteRole",
        "iam:AttachRolePolicy", "iam:DetachRolePolicy",
        "iam:CreatePolicy", "iam:DeletePolicy",
        "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
        "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
        "iam:PassRole", "iam:GetRole", "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies", "iam:GetInstanceProfile",
        "iam:TagRole", "iam:TagPolicy", "iam:TagInstanceProfile",
        "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions"
      ],
      "Resource": "*"
    }
  ]
}
```
</details>

### 2c. Create access keys

After creating the user:

1. Go to the user → **Security credentials** tab → **Create access key**
2. Select **Command Line Interface (CLI)**
3. Download or copy the **Access key ID** and **Secret access key** — you will not see the secret again

---

## 3. Install the AWS CLI (v2)

| OS | Instructions |
|----|--------------|
| Windows | Download from https://awscli.amazonaws.com/AWSCLIV2.msi and run the installer |
| macOS | `brew install awscli` or download from AWS |
| Linux | `curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip && unzip awscliv2.zip && sudo ./aws/install` |

Verify: `aws --version`

### Configure credentials

```bash
aws configure
```

When prompted:
```
AWS Access Key ID:     <paste Access key ID from step 2c>
AWS Secret Access Key: <paste Secret access key from step 2c>
Default region:        us-east-1
Default output format: json
```

Credentials are saved to `~/.aws/credentials`.

Verify access:
```bash
aws sts get-caller-identity
```

You should see your account ID and `terraform-htcondor-poc` as the user ARN.

---

## 4. Install the AWS Session Manager Plugin

This plugin lets `aws ssm start-session` open interactive shell sessions
to your instances (no public IPs, no SSH, no RDP exposed to the internet).

| OS | Command |
|----|---------|
| Windows | Download from https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPluginSetup.exe |
| macOS | `brew install --cask session-manager-plugin` |
| Linux (deb) | Download and `dpkg -i session-manager-plugin.deb` from the AWS docs page |

AWS docs: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html

Verify: `session-manager-plugin --version`

---

## 5. Install Terraform

| OS | Instructions |
|----|--------------|
| Windows | Download from https://developer.hashicorp.com/terraform/downloads, extract `terraform.exe`, add to PATH |
| macOS | `brew tap hashicorp/tap && brew install hashicorp/tap/terraform` |
| Linux | Follow https://developer.hashicorp.com/terraform/install |

Verify: `terraform version` — must be ≥ 1.5.0.

---

## 6. EC2 Key Pair

Terraform **automatically creates** an RSA-4096 key pair and saves the private key
as `terraform/htcondor-poc-key.pem` in your project directory. You do not need to
create one manually.

The key pair is only needed if you want to decrypt the initial Windows Administrator
password via the EC2 console ("Get Windows password"). For normal access you use
SSM Session Manager (see DEPLOY.md).

> **Keep `htcondor-poc-key.pem` safe.** It is created in `terraform/` and is in
> `.gitignore`. Do not commit it.

---

## 7. Download the HTCondor 23.4.0 Windows MSI

1. Go to https://htcondor.org/htcondor/download/
2. Select version **23.4.0**, platform **Windows**, architecture **x86_64**
3. Download the `.msi` file to your local machine

You will upload it to S3 in **DEPLOY.md step 3** before the instances start
their setup scripts.

---

## Checklist

- [ ] IAM user `terraform-htcondor-poc` created with access keys
- [ ] `aws configure` completed; `aws sts get-caller-identity` returns expected user
- [ ] AWS CLI v2 installed
- [ ] Session Manager plugin installed; `session-manager-plugin --version` works
- [ ] Terraform ≥ 1.5.0 installed; `terraform version` works
- [ ] HTCondor 23.4.0 Windows MSI downloaded locally

Once all boxes are checked, proceed to **DEPLOY.md**.
