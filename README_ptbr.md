# Migrando para o Terraform

## Introdução

Recentemente uma companhia de desenvolvimento nos contactou [flugel.it](http://flugel.it/)
para ajudarmos na administração de um site rodando na Amazonaws. É um CMS muito
popular, usando LAMP junto com RDS e ElasticCache, tendo variações no trafego,
especialmente em dias de transmissões de eventos via stream

*Nota* Esta é uma tradução do artigo original em: [moving-to-terraform](https://github.com/flugel-it/moving-to-terraform).
Lá você encontra todos os arquivos de configuração aqui usados

## Desafios e primeiros passos

Nosso primeiro desafio foi migrar a aplicação do código do CloudFormation para o
Terraform. O problema aqui é que, como mencionei anteriormente, sua plataform já
estava em produção, usando RDS e ElasticCache e rodando em um VPC dedicado, e
para ter um migração sem afetar os usuários, nós precisavamos integrar Terraform
com o que já existia

## Requisitos

Seguindo com este exemplo, nós precisamos criar alguns recursos na AWS para simular
o mesmo ambiente.

- Uma conta na AWS
- 1 VPC [ Neste exemplo: vpc-1329f474]
- 2 Subnets [ Neste exemplo: subnet-e2e6d294 and subnet-e32662c9 ]
- 1 Key Pair [ Neste exemplo: abednarik ]

## Terraform

### O que é o Terraform?

Terraform é uma ferramenta para construir, manter e versionar a infra estrutura
como código, segura e efeiciente. Ele também pode gerenciar outros serviços de
Cloud.

### Configuração

A primeira coisa que devemos fazer é criar algumas variáveis. *aws_ami* vai
armazena nossa AMI, e será a mesma in todos os ambientes.

```
variable "aws_ami" {
  description = "The AWS AMI to use."
  default = "ami-fce3c696"
}
```

Neste caso eu prefiro armazenar as variáveis em um único arquivo [variables.tf](https://github.com/flugel-it/moving-to-terraform/blob/master/variables.tf).
Dê uma olhada neste arquivo para estar mais familiarizado.

Agora, vamos iniciar com [main.tf](https://github.com/flugel-it/moving-to-terraform/blob/master/main.tf).
Aqui nós definimos todos os recursos que nós planejamos usar em nosso ambiente.

Definimos o provider (aws neste caso) e a AWS Region

```
provider "aws" {
  region = "${var.aws_region}"
}
```

Então é necessário definir o Security Group:

```
resource "resource_type" "resource_name" {
[...]
}
```

onde *resource_type* é o recurso que queremos configurar, neste caso *aws_security_group* e
*resource_name* é o nome que queremos dar ao recurso. Finalmente dentro das 'chaves',
definimos a configuração daquele recurso.

Aqui esta um exemplo, um Security Group para o nosso Elastic Load Balancer. Como
você pode ver, nós usamos *${var.environment}* como valor na definição de Name e
Tag. Isto nos permite reusar o mesmo código em diferentes ambientes somente alterando
uma variável.
Neste exemplo, nós permitimos tráfego HTTP vindo da Internet para todas instancias
em nossa vpc *${var.vpc_id}*.

```
resource "aws_security_group" "elb-sg" {
  name = "sg_elb_${var.environment}"
  vpc_id = "${var.vpc_id}"

  # HTTP access from anywhere
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # outbound internet access
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "sg-elb-${var.environment}"
  }
}
```

Depois disso, criamos nosso ELB. Aqui existem algumas coisas que precisamos nos
atentar:

- *security_groups*: Quando usamos _${aws_security_group.elb-sg.id}_ Terraform
pode selecionar o SG dinamicamente e associar para o nosso ELB.
- *subnets*: Note que estamos usando 'chaves' aqui, o que significa que é uma lista
de valores. Como temos mais de uma subnet, nós queremos ter certeza que ELB pode
escolher instancias em qualquer subnet dentro do nosso VPC.
- *listener*: Define protocolos e portas do ELB e para cada instância.
- *health_check*: Define o modo que vamos validar se nossas instancias estão funcionando
corretamente, neste uma checagem simples via HTTP

E finalmente o último bloco define alguns valores para o ELB, o mais importante é
*cross_zone_load_balancing* que distribui tráfego entrante entre as instãncias,
não importa a zona onde elas estão.

```
resource "aws_elb" "web-elb" {
  name = "elb-web-${var.environment}"
  security_groups = ["${aws_security_group.elb-sg.id}"]

  subnets = ["${split(",", var.subnet_ids)}"]
  listener {
    instance_port = 80
    instance_protocol = "http"
    lb_port = 80
    lb_protocol = "http"
  }

  health_check {
    healthy_threshold = 2
    unhealthy_threshold = 2
    timeout = 3
    target = "HTTP:80/index.html"
    interval = 30
  }

  cross_zone_load_balancing = true
  idle_timeout = 400
  connection_draining = true
  connection_draining_timeout = 400

  tags {
    Name = "elb-web-${var.environment}"
  }
}

```

Agora é hora de definir o Launch Configuration. É o que é executando quando uma
nova instância é criada decorrente de uma ação do autoscaling.
Algumas coisas importantes aqui:
- *name_prefix*: Não se pode sobrescrever ou modificar todo momento que queremos,
modificar algo, então usamos um prefixo. Toda vez que algo é modificado, um novo
launch configuration será criado dinamicamente
- *user_data*: Template onde colocamos nossos dados ou scripts para configurar
cada instância. Neste caso vou utilizar um simples shell script.
- *lifecycle*: Como launch configurations não pode ser modificado, nos asseguramos
em criar uma nova configuração antes de remover a anterior

```

/* Launch Configuration for Autoscalling Group */
resource "aws_launch_configuration" "web-lc" {
  name_prefix = "lc-web-${var.environment}-"
  image_id = "${var.aws_ami}"
  instance_type = "${var.app_instance_type}"
  security_groups = ["${aws_security_group.default.id}"]
  user_data = "${element(template_file.bootstrap.*.rendered, count.index)}"
  key_name = "abednarik"

  lifecycle {
    create_before_destroy = true
  }
}
```

Para completar nossa configuração, precisamos definir um template para carregar
nosso script. Segue um exemplo:

```
resource "template_file" "bootstrap" {
    template = "${file("files/bootstrap.sh")}"
    vars {
        cluster_name = "web-${var.environment}"
        roles = "web"
        environment = "${var.environment}"
    }

    lifecycle {
      create_before_destroy = true
    }
}
```

Agora é hora de criarmos um *autoscaling_group* que usando os alertas do CloudWatch,
nossa infra pode aumentar e diminuir conforme o tráfego, reduzindo os custos.
Como você pode ver, nós referenciamos nosso *launch_configuration*, usando nosso
*VPC* e *subnets* e definindo o número desejado de instâncias, assim como seu limite
máximo e mínimo.


```
resource "aws_autoscaling_group" "web-asg" {
  availability_zones = ["${split(",", var.availability_zones)}"]
  name = "asg-web-${var.environment}"
  max_size = "${var.asg_max}"
  min_size = "${var.asg_min}"
  desired_capacity = "${var.asg_desired}"
  force_delete = true
  launch_configuration = "${aws_launch_configuration.web-lc.name}"
  load_balancers = ["${aws_elb.web-elb.name}"]
  vpc_zone_identifier = ["${split(",", var.subnet_ids)}"]
  tag {
    key = "Name"
    value = "web-${var.environment}"
    propagate_at_launch = "true"
  }
  tag {
    key = "Environment"
    value = "${var.environment}"
    propagate_at_launch = "true"
  }
}
```

Agora precisamos de um SG para cada instância, permitindo acesso HTTP e SSH vindo
da Internet. É Altamente recomendável permitir acesso SSH de dentro de sua VPC, mas
este é apenas um exemplo e usaremos Bastion Host para acessar nossa infraestrutura.


```
resource "aws_security_group" "default" {
  name = "sg_web_${var.environment}"
  vpc_id = "${var.vpc_id}"

  # SSH access from anywhere
  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP access from anywhere
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # outbound internet access
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "sg-ec2-web-${var.environment}"
  }
}
```

### Rodando Terraform

Agora que a configuração esta completa, é hora de executarmos e criarmos todos os nossos recursos na nossa AWS.

- Primeiramente vamos exportar nossas credencias da AWS. Troque *XXX* e *YYY* por suas credenciais

```
export AWS_ACCESS_KEY_ID=XXX
export AWS_SECRET_ACCESS_KEY=YYY
```

- Crie um arquivo .tfvar com os dados apropriados. Segue um [exemplo][https://github.com/flugel-it/moving-to-terraform/blob/master/example.tfvars]

```
environment = "example"
aws_region="us-east-1"
availability_zones = "us-east-1b,us-east-1c"
vpc_id = "vpc-1329f474"
subnet_ids = "subnet-e2e6d294,subnet-e32662c9"
app_instance_type = "t2.micro"
asg_min = "1"
asg_max = "2"
asg_desired = "1"
```

- Verifique as configurações e veja quais recursos serão criados

```
terraform  plan -var-file example.tfvars
```

É sempre uma boa idéia usar *terraform plan* antes de aplicar as modificações, assim
podemos saber todas as modificações e validar a configuração

- Run Terraform

```
terraform  apply -var-file example.tfvars
```

Isto pode levar um tempo até que as instâncias estejam prontas e você pode verificar
no seu AWS Console. Segue um exemplo se tudo ocorreu bem [outputs.tf][https://github.com/flugel-it/moving-to-terraform/blob/master/outputs.tf].
Podemos agora validar se tudo esta funcionando corretamente:

```
curl -v elb-web-example-213959227.us-east-1.elb.amazonaws.com
```

ou

```
wget -O -  -S elb-web-example-213959227.us-east-1.elb.amazonaws.com
```

Excellent! Terraform is working :D
Excelente! Terraform esta funcionando :D

- Agora podemos destruir tudo que haviamos criado.

```
terraform  destroy -var-file example.tfvars
```

Digite *yes* quando Terraform pedir que confirme.

## Gerenciamento de Configuração e Automação

Como mencionei, nós usamos um simples shell script. Neste usamos SlatStack como
orquestrador, mas você pode usar aquele que preferir: Chef, Ansible, Puppet, etc.

```
apt-get update
apt-get install -y curl wget python-pip

cd /tmp && wget -O install_salt.sh https://bootstrap.saltstack.com
sh install_salt.sh -i $(echo $HOSTNAME) -P git v2015.8.10
restart salt-minion

salt-call --local grains.setval roles ${roles}
salt-call --local grains.setval environment ${environment}
salt-call state.highstate
```

## Conclusion

Terraform provavelmente é a melhor ferramenta que já utilizamos para gerenciar
recursos na Cloud. É muito simples de usar e entender, muito bem documentada,
com bastante exemplos e o melhor, que funcionam :). O que mais você quer?
Agora você não tem mais desculpas para não usar ;)
Happy hacking.
