# Migrando a Terraform

## Introduccion

Recientemente una compañia de Desarrollo nos contacto en [flugel.it](http://flugel.it/)
para ayudarlos a administrar un Site en AWS WebServices. El Site, basado en un popular
CMS, corriendo en un stack LAMP y utilizando servicios como RDS para Base de Datos y ElasticCache
para cache. La particularidad de este Site es que el tráfico varía mucho, ya que manejan
eventos, donde el tráfico crece significativamente con respecto a las visitas que tienen
habitualmente.

## Desafío y Primeros Pasos

Nuestro primer desafío fue mover application servers a partir de un código de CloudFormation
a Terraform. El problema aquí es que, como ya mencioné, la Plataforma ya está en
producción y tanto RDS como ElasticCache estan dentro de una VPC dedicada, por lo que hay
que reutilizar e integrar algunos recursos previamente existentes en Terraform sin afectar el correcto
funcionamiento del Site.

## Requerimientos

Para seguir este ejemplo y reproducir la situación en la que comenzamos a trabajar es
necesario contar con los siguientes recursos previamente creados en AWS.


- Una cuenta en AWS
- 1 VPC [ En este ejemplo: vpc-1329f474]
- 2 Subnets [ En este ejemplo: subnet-e2e6d294 y subnet-e32662c9 ]
- 1 Key Pair [ En este ejemplo: abednarik ]

## Terraform

### Que es Terraform?

Terraform es una herramienta para la creacion, modificación y control de versiones de la infraestructura
de forma segura y eficiente. Terraform puede gestionar los proveedores mas populares de servicios Cloud existentes.

### Configuracion de Terraform

*Nota* para seguir este artículo, se hiciseron algunas pequeñas modificaciones en la configuracion de Terraform
de modo que cualquiera  puede seguir esta guía.

En primer lugar, puedes revisar [moving-to-terraform](https://github.com/abednarik/moving-to-terraform), en donde se
pueden ver todos los archivos involucrados en este artículo.

Lo primero que tenemos que conocer es como crear variables. Estas guardan información que utilizaremos luego.
La definición de una variable es bastante simple.
En este caso, definimos una variable *aws_ami*, establecemos una descripción y, finalmente, un valor por defecto.
En este caso, asignamos un valor por default ya que la intención es utilizar la mismo AMI en todos los ambientes,
es probablemente una de las pocas variables que queremos tener exactamente igual en todos los ambientes.

```
variable "aws_ami" {
  description = "The AWS AMI to use."
  default = "ami-fce3c696"
}
```

Todas las variables estan definidas en el archivo [variables.tf](https://github.com/abednarik/moving-to-terraform/blob/master/variables.tf).

Ahora, vamos a empezar a trabajar con [main.tf](https://github.com/abednarik/moving-to-terraform/blob/master/main.tf). Aquí es donde  definimos todos los recursos que vamos a usar en AWS.
En primer lugar, definimos el proveedor. Terraform soporta múltiples proveedores, como AWS WebServices, DigitalCcean,
Azure, Google Cliud, OpenStack y otros.

Establecemos el proveedor y la región de AWS en *variables.tf*:

```
provider "aws" {
  region = "${var.aws_region}"
}
```

A continuación vamos a establecer  un Security Group. Terraform soporta muchismos recursos. La forma de definir uno
es de la siguiente formato: *resource*  *"resource_type"* *"resource_name"* donde *resource_type*
es el recurso que queremos configurar, en este caso *resource_name* es el nombre que asignamos nosotros para luego
referenciar en nuestra configuración de Terraform. finalmente dentro de la definición de recursos establecemos la
configuración para ese recurso.

A continuacion un recurso completo, un Security Group para ELB. Como se puede ver, utilizamos
una variable *${var.environment}* a incluir en el Nombre y también en el Tag. Esto nos permite reutilizar
este código para distintos ambiente, simplemente cambiando una variable.
Este Security Group es muy sencillo, permite trafico HTTP desde internet y cualquier tipo de trafico dentro
de nuestra VPC *${var.vpc_id}*

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

Después de eso, necesitamos crear un ELB. Aquí hay algunas cosas a tener en cuenta:

- *security_groups*: Como se puede ver aquí usamos _${aws_security_group.elb-sg.id}_
esto significa que Terraform va a asociar a este recurso el Security Group que definimos previamente.
- *subnets* Aca usamos corchetes, lo que significa que se trata de una lista de múltiples
valores. Ya que tenemos más de una subnet, queremos asegurarnos de que el ELB puede alcanzar instancias
en cualquier subnet dentro de nuestro VPC.
- *listener*: Este bloque es donde se define protocolos y puertos, tanto para el ELB y para cada
Instancia.
- *health_check*: Aquí establecemos cómo podemos validar que nuestras instancias están funcionando correctamente
haciendo un check HTTP sencillo

Y, finalmente, el último bloque de configuracion donde hay algunos valores para el ELB, el más importante es
*cross_zone_load_balancing* para distribuir el tráfico entrante de manera uniforme entre todas las instancias
no importa en qué zona se encuentran ubicados.

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

Ahora es el momento de definir la configuración para Launch Configuration. Esto es básicamente lo que se ejecuta cuando una
nueva instancia se crea en base a una acción de AutoScalling.
Algunas cosas importantes a destacar aquí:
- *name_prefix* Este tipo de recursoo no se puede sobrescribir o modificar, por lo tanto cada vez que queremos
cambiar algo, necesitamos una nueva configuración, por esto usamos prefix.
- *user_data*: Esta es el template en donde manejamos nuestros datos / script para configurar cada instancia. luego
agregare un simple shell script para hacerlo.
- *lifecycle*: Como este recurso es unico, queremos asegurarnos de que una nueva configuración
se crea antes de eliminar la anterior.

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

Para completar esta configuracion necesitamos definir un template.
Aquí un ejemplo sencillo para hacer eso

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

Ahora es el momento de crear un *autoscaling_group* para poder aprovechar esta funcionalidad de AWS.
Esto, junto con una alerta en CloudWatch permitirá que nuestra stack crezca cuando hay más tráfico
y se reduzca cuando no hay necesidad de tener demasiados recursos para reducir costos.
Como se puede ver  hacemos referencia a al recurso *launch_configuration*, creado anteriormente,
usamos nuestra *VPC* y *subnets* y establecemos el número deseado de instancias, junto con los límites máximos y
mínimas.

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


Por último, necesitamos un Security Group para las instancias. Como se puede ver esto es bastante simple
y similar al Security Group creado para el ELB. Permitimos HTTP y SSH  desde internet.
Esto está  bien, en el contexto de este ejemplo, pero *recomiendo* sólo permitir ssh desde el interior
de la VPC, con un jump hosts.


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

### Ejecutando Terraform

Ahora que se ha completado la configuración Terraform, es el momento de ejecutarlo y crear todos los recursos de AWS.

- En primer lugar exportar sus credenciales de AWS, cambiar *XXX* y *YYY* con las keys reales :)


```
export AWS_ACCESS_KEY_ID=XXX
export AWS_SECRET_ACCESS_KEY=YYY
```

- Crear un archivo .tfvars con los datos propios. Yo siempre uso el nombre del entorno para este archivo.
Este es un ejemplo creado para este ejemplo. Basta con sustituir estos valores con los datos de cada uno.

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

- Ahora podemos ver que va a ejecutar Terraform y validar el codigo

```
terraform  plan -var-file example.tfvars
```

Es muy util y una buena practica usar *terraform plan* and de realizar algun cambio, ya que podemos ver que
cambio se van a hacer en nuestra Infrastructura.


- Ejecutar Terraform

```
terraform  apply -var-file example.tfvars
```

Esto va a tomar un tiempo, ya que estamos usando una instancia muy pequeña. Hay que esperar unos
minutos hasta que la instancia este lista.
Si todo salio bien Terraform nos va a mostrar lo que tenemos definido en [outputs.tf][https://github.com/abednarik/moving-to-terraform/blob/master/outputs.tf]
Este archivo se usa para obtener recursos generados en AWS que previamente no podemos conocer.
En este caso el fqdn del ELB. Este es el fqdn que resulto luego de ejecutar Terraform: *elb-web-example-213959227.us-east-1.elb.amazonaws.com*
Ahora podemos validar que Nginx este funcionando correctamente utilizando wget o curl:

```
curl -v elb-web-example-213959227.us-east-1.elb.amazonaws.com
```

o

```
wget -O -  -S elb-web-example-213959227.us-east-1.elb.amazonaws.com
```

- Finalmente podes destruir los recursos, ya que no nos interesa mantenerlos.

```
terraform  destroy -var-file example.tfvars
```

Terraform nos pide conformacion cuando queremos destruir los recursos, para eso hay que confirmar
con *yes*.

## Configuration Managementy Automatización

Como ya mencioné aquí usamos sólo un simple shell script. Lo ideal sería utilizar algunas de las opciones
mas populares como Puppet, Chef o SaltStack para hacer un setup completo.
Aca un ejemplo de como lo uso con SaltStack:

```
apt-get update
apt-get install -y wget python-pip

cd /tmp && wget -O install_salt.sh https://bootstrap.saltstack.com
sh install_salt.sh -i $(echo $HOSTNAME) -P git v2015.8.10
restart salt-minion

salt-call --local grains.setval roles ${roles}
salt-call --local grains.setval environment ${environment}
salt-call state.highstate
```

## Conclusión

Terraform es probablemente una de las mejores herramientas que hay para manejar infrastructuras en el Cloud.
Es fácil, bien documentada, hay muchisimos ejemplos y funciona muy bien :)
