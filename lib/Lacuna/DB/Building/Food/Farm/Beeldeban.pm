package Lacuna::DB::Building::Food::Farm::Beeldeban;

use Moose;
extends 'Lacuna::DB::Building::Food::Farm';

use constant controller_class => 'Lacuna::Building::Beeldeban';

use constant building_prereq => {'Lacuna::DB::Building::Food::Farm::Wheat'=>5};

use constant image => 'beeldeban';

use constant min_orbit => 2;

use constant max_orbit => 4;

use constant name => 'Beeldeban Herder';

use constant food_to_build => 100;

use constant energy_to_build => 100;

use constant ore_to_build => 125;

use constant water_to_build => 50;

use constant waste_to_build => 35;

use constant time_to_build => 800;

use constant food_consumption => 5;

use constant beetle_production => 35;

use constant energy_consumption => 2;

use constant ore_consumption => 4;

use constant water_consumption => 3;

use constant waste_production => 23;

use constant waste_consumption => 15;



no Moose;
__PACKAGE__->meta->make_immutable;
