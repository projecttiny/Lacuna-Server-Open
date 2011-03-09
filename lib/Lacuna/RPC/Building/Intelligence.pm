package Lacuna::RPC::Building::Intelligence;

use Moose;
use utf8;
no warnings qw(uninitialized);
extends 'Lacuna::RPC::Building';
use Lacuna::Util qw(randint);

with 'Lacuna::Role::Captcha::AssignSpies';

sub app_url {
    return '/intelligence';
}

sub model_class {
    return 'Lacuna::DB::Result::Building::Intelligence';
}

sub view_spies {
    my ($self, $session_id, $building_id, $page_number) = @_;
    my $empire = $self->get_empire_by_session($session_id);
    my $building = $self->get_building($empire, $building_id);
    $page_number ||= 1;
    my @spies;
    my $body = $building->body;
    my %planets = ( $body->id => $body );
    my $spy_list = $building->get_spies->search({}, { rows => 25, page => $page_number});
    my $cost_to_subsidize = 0;
    while (my $spy = $spy_list->next) {
        if (exists $planets{$spy->on_body_id}) {
            $spy->on_body($planets{$spy->on_body_id});
        }
        else {
            $planets{$spy->on_body_id} = $spy->on_body;
        }
        $cost_to_subsidize++ if ($spy->task eq 'Training');
        push @spies, $spy->get_status;
    }
    my @assignments = Lacuna::DB::Result::Spies->assignments;
    return {
        status                  => $self->format_status($empire, $body),
        spies                   => \@spies,
        possible_assignments    => \@assignments,
        spy_count               => $spy_list->pager->total_entries,
        cost_to_subsidize       => $cost_to_subsidize,
    };
}


sub subsidize_training {
    my ($self, $session_id, $building_id) = @_;
    my $empire = $self->get_empire_by_session($session_id);
    my $building = $self->get_building($empire, $building_id);
    my $body = $building->body;

    my $spies = $building->get_spies->search({ task => 'Training' });

    my $cost = $spies->count;
    unless ($empire->essentia >= $cost) {
        confess [1011, "Not enough essentia."];    
    }

    $empire->spend_essentia($cost, 'spy training subsidy after the fact');    
    $empire->update;

    my $now = DateTime->now;
    while (my $spy = $spies->next) {
        $spy->available_on($now);
        $spy->task('Idle');
        $spy->update;
    }
    $building->finish_work->update;

    return $self->view($empire, $building);
}


sub assign_spy {
    my ($self, $session_id, $building_id, $spy_id, $assignment) = @_;
    my $empire = $self->get_empire_by_session($session_id);
    my $building = $self->get_building($empire, $building_id);
    my $spy = $building->get_spy($spy_id);
    unless (defined $spy) {
        confess [1002, "Spy not found."];
    }
    my $mission = $spy->assign($assignment);
    return {
        status  => $self->format_status($empire, $building->body),
        mission => $mission,
        spy     => $spy->get_status,
    };
}

sub burn_spy {
    my ($self, $session_id, $building_id, $spy_id, $assignment) = @_;
    my $empire = $self->get_empire_by_session($session_id);
    my $building = $self->get_building($empire, $building_id);
    my $spy = $building->get_spy($spy_id);
    unless (defined $spy) {
        confess [1002, "Spy not found."];
    }
    if ($spy->task eq 'Waiting On Trade') {
        confess [1010, "You can't burn a spy involved in a trade. You must wait for the trade to complete."];
    }
    if ($spy->task eq 'Captured') {
        confess [1010, "You can't burn a spy that has been captured. If you did he would have no reason not to tell your enemy all your secrets."];
    }
    $spy->burn;
    return {
        status  => $self->format_status($empire, $building->body),
    };
}

sub train_spy {
    my ($self, $session_id, $building_id, $quantity) = @_;
    my $empire = $self->get_empire_by_session($session_id);
    my $building = $self->get_building($empire, $building_id);
    $quantity ||= 1;
    if ($quantity > 5) {
        confess [1009, "You can only train 5 spies at a time."];
    }
    my $trained = 0;
    my $body = $building->body;
    if ($building->level < 1) {
        confess [1013, "You can't train spies until your Intelligence Ministry is completed."];
    }
    my $costs = $building->training_costs;
    SPY: foreach my $i (1..$quantity) {
        if (eval{$building->can_train_spy($costs)}) {
            $building->spend_resources_to_train_spy($costs);
            $building->train_spy($costs->{time});
            $trained++;
        }
        else {
            last SPY;
        }
    }
    if ($trained) {
        $body->update;
        if ($trained >= 3) {
            $body->add_news(50, '%s has just approved a massive intelligence budget increase.', $empire->name);
        }
    }
    return {
        status  => $self->format_status($empire, $body),
        trained => $trained,
        not_trained => $quantity - $trained,
        building                    => {
            work        => {
                seconds_remaining   => $building->work_seconds_remaining,
                start               => $building->work_started_formatted,
                end                 => $building->work_ends_formatted,
            },
        },
    },
}

around 'view' => sub {
    my ($orig, $self, $session_id, $building_id) = @_;
    my $empire = $self->get_empire_by_session($session_id);
    my $building = $self->get_building($empire, $building_id, skip_offline => 1);
    my $out = $orig->($self, $empire, $building);
    $out->{spies} = {
        maximum         => $building->max_spies,
        current         => $building->spy_count,
        training_costs  => $building->training_costs,
        in_training     => $building->spies_in_training_count,
    };
    return $out;
};

sub name_spy {
    my ($self, $session_id, $building_id, $spy_id, $name) = @_;
    Lacuna::Verify->new(content=>\$name, throws=>[1005, 'Invalid name for a spy.'])
        ->not_empty
        ->no_profanity
        ->length_lt(31)
        ->length_gt(2)
        ->no_restricted_chars;
    my $empire = $self->get_empire_by_session($session_id);
    my $building = $self->get_building($empire, $building_id);
    my $spy = $building->get_spy($spy_id);
    $spy->name($name);
    $spy->update;
    return {
        status  => $self->format_status($empire, $building->body),
    };
    
}

__PACKAGE__->register_rpc_method_names(qw(view_spies assign_spy train_spy burn_spy name_spy subsidize_training));


no Moose;
__PACKAGE__->meta->make_immutable;

