resource "aws_instance" "instance" {
  depends_on                  = [aws_s3_bucket_object.object]
  ami                         = "ami-0ff4c8fb495a5a50d"
  instance_type               = "t2.small"
  associate_public_ip_address = true
  monitoring                  = true
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.allow_ssh.id]
  tags = {
    Name = "Strapi Server"
  }

  iam_instance_profile = "ec2-access-s3"

  user_data = <<EOF
#!/bin/bash
sudo apt update
sudo apt install build-essential curl unzip -y

echo "${aws_s3_bucket_object.object.etag}" # Just to force update

ln /usr/bin/python3 /usr/bin/python

curl https://gist.githubusercontent.com/ebdmuir/785b924e4fd4da706bd5749db413eada/raw/3eac12f501926beb0abc8cd04548e7e241fd0391/aws-cli-ubuntu | sh

curl -sL https://deb.nodesource.com/setup_12.x | sudo -E bash -
sudo apt-get install nodejs

su ubuntu -c "mkdir ~/.npm-global && npm config set prefix '~/.npm-global'"
su ubuntu -c "npm i -g pm2"
su ubuntu -c "echo 'export PATH=~/.npm-global/bin:$PATH' >> ~/.profile"

aws s3 cp s3://franscape-data-archive/strapi.zip /home/ubuntu
chown ubuntu:ubuntu /home/ubuntu/strapi.zip
unzip /home/ubuntu/strapi.zip -d /home/ubuntu/strapi
chown ubuntu:ubuntu -R /home/ubuntu/strapi

su ubuntu -c "cd ~/strapi && npm install && NODE_ENV=production npm run build"
su ubuntu -c "/home/ubuntu/.npm-global/bin/pm2 start ~/strapi/ecosystem.config.js"

echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDPspTmajJM27BckXYS/37sXNLiShsMoERkUbBjLt4uSgpdaxgVmxEWunMeQy53VsdBtyVpMIwnZzTeabiOY3bUGqAe/gGWDKS9mPKigPWNX5caVJficPWzmVeuDEfbm1AHkcDzzK4i9Qw98d2nvP+7EJulJ0Q6lhHxLz20zxKbYR1KbwuGDkPHK4Gh51NfohGG2+0m+mszEHnhlN6HURsU7C9xshCrPfNEie0+tlGHjq/2tiXrxZqlDJT8XZoINCon/CqdYLzkYBX/QiABrqi/qICBwSpRU6b0GVzIoe/0UfRSeK9VNqIsQDOGPhHGbSgsUrWoiCTKh7LKtaSk3I1LfLO6CUoeJ8PGgnh11caOUAIpfoaVuu4PuPBuvyCyQxt2O7b1W08q1DqOfDqM0uioPQ8u9gOB9zKgK5K+VBf9+R0LeGibN+sRS4BcKpKwAj2/FBulOendwTuF5FhGL1lyRWhdgTKxoqLOkSSTuGXB4suuwro5s9d8iqzhqiDkgU0= ericmuir@devmac.local" > /home/ubuntu/.ssh/authorized_keys
EOF

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "lb_secgroup" {
  name        = "strapi_lb_secgroup"
  description = "Allow TLS inbound traffic"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "TLS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "strapi_lb_secgroup"
  }
}

resource "aws_lb" "api" {
  name            = "strapi-lb"
  internal        = false
  subnets         = module.vpc.public_subnets
  security_groups = [aws_security_group.lb_secgroup.id]

  tags = {
    Name = "strapi_api_alb"
  }
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate.cert.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_lb_target_group" "api" {
  name     = "strapi-api"
  port     = 1337
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id
}

resource "aws_lb_target_group_attachment" "main" {
  target_group_arn = aws_lb_target_group.api.arn
  target_id        = aws_instance.instance.id
  port             = 1337

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "server" {
  name            = "server.${var.id}.strapi.franscape.io"
  type            = "A"
  zone_id         = "Z09936565SB6P6INZE3R"
  ttl             = 60
  records         = [aws_instance.instance.public_ip]
  allow_overwrite = true
}

resource "aws_route53_record" "api" {
  name            = "${var.id}.strapi.franscape.io"
  type            = "CNAME"
  zone_id         = "Z09936565SB6P6INZE3R"
  ttl             = 60
  records         = [aws_lb.api.dns_name]
  allow_overwrite = true
}