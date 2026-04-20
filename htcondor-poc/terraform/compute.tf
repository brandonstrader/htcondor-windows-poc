locals {
  # Common bootstrap template inputs. Role lets the bootstrap pick the right
  # setup script at later stages; at v1 the bootstrap is a no-op.
  bootstrap_vars = {
    bucket     = aws_s3_bucket.artifacts.id
    region     = var.aws_region
    ssm_prefix = local.ssm_prefix
  }
}

# ── Domain Controller ────────────────────────────────────────────────────────
resource "aws_instance" "dc" {
  ami                    = data.aws_ami.windows_2022.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.main.key_name
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.instances.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  private_ip             = local.dc_ip

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 60
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/userdata/bootstrap.ps1.tftpl", merge(local.bootstrap_vars, {
    role = "dc"
  })))

  tags = { Name = "dc" }
}

# ── Central Manager (future HTCondor CM + CREDD) ────────────────────────────
resource "aws_instance" "cm" {
  ami                    = data.aws_ami.windows_2022.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.main.key_name
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.instances.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  private_ip             = local.cm_ip

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 60
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/userdata/bootstrap.ps1.tftpl", merge(local.bootstrap_vars, {
    role = "cm"
  })))

  tags = { Name = "mgr" }
}

# ── Submit Node (ws-0) ───────────────────────────────────────────────────────
resource "aws_instance" "submit" {
  ami                    = data.aws_ami.windows_2022.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.main.key_name
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.instances.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  private_ip             = local.submit_ip

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 60
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/userdata/bootstrap.ps1.tftpl", merge(local.bootstrap_vars, {
    role = "submit"
  })))

  tags = { Name = "ws-0" }
}

# ── Execute Node (compute-0) ─────────────────────────────────────────────────
resource "aws_instance" "execute" {
  ami                    = data.aws_ami.windows_2022.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.main.key_name
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.instances.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  private_ip             = local.execute_ip

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 60
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/userdata/bootstrap.ps1.tftpl", merge(local.bootstrap_vars, {
    role = "execute"
  })))

  tags = { Name = "compute-0" }
}
